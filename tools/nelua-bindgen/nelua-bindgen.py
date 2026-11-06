#!/usr/bin/env python3
"""nelua-bindgen: generate Nelua `<cimport>` bindings from C headers using libclang.

Usage:
  nelua-bindgen.py header.h [header2.h ...] [-I dir] [-D name[=value]] [--include-as '<zlib.h>']
                   [--prefix NS] [--match REGEX] [--exclude REGEX] [--opaque NAME] [--enum-using]
                   [--nullable-returns REGEX]
                   [--all] [--no-stubs] [--config FILE] [-o out.nelua]

Requires the libclang Python bindings (Debian/Ubuntu: `apt install python3-clang`).
"""
import argparse
import json
import os
import re
import sys

try:
    from clang import cindex
    from clang.cindex import CursorKind, TypeKind
except ImportError:  # pragma: no cover
    sys.stderr.write("nelua-bindgen: the libclang Python bindings are missing (pip install libclang, or apt install python3-clang)\n")
    sys.exit(2)

NELUA_KEYWORDS = {
    'and', 'break', 'case', 'continue', 'defer', 'do', 'else', 'elseif', 'end', 'fallthrough', 'false',
    'for', 'function', 'global', 'goto', 'if', 'in', 'local', 'nil', 'not', 'or', 'repeat', 'return',
    'switch', 'then', 'true', 'until', 'while',
}

# Nelua names for C builtin type kinds.
PRIM_KINDS = {
    TypeKind.VOID: 'void',
    TypeKind.BOOL: 'boolean',
    TypeKind.CHAR_U: 'cchar', TypeKind.CHAR_S: 'cchar',
    TypeKind.UCHAR: 'cuchar', TypeKind.SCHAR: 'cschar',
    TypeKind.CHAR16: 'uint16', TypeKind.CHAR32: 'uint32',
    TypeKind.WCHAR: 'cwchar_t',
    TypeKind.USHORT: 'cushort', TypeKind.SHORT: 'cshort',
    TypeKind.UINT: 'cuint', TypeKind.INT: 'cint',
    TypeKind.ULONG: 'culong', TypeKind.LONG: 'clong',
    TypeKind.ULONGLONG: 'culonglong', TypeKind.LONGLONG: 'clonglong',
    TypeKind.UINT128: 'uint128', TypeKind.INT128: 'int128',
    TypeKind.FLOAT: 'float32', TypeKind.DOUBLE: 'float64', TypeKind.LONGDOUBLE: 'clongdouble',
    TypeKind.FLOAT128: 'float128',
}

# Nelua names for well known C typedefs (resolved by name, so the target decides their size).
PRIM_TYPEDEFS = {
    'size_t': 'csize', 'ptrdiff_t': 'cptrdiff', 'ssize_t': 'isize',
    'intptr_t': 'isize', 'uintptr_t': 'usize',
    'int8_t': 'int8', 'int16_t': 'int16', 'int32_t': 'int32', 'int64_t': 'int64',
    'uint8_t': 'uint8', 'uint16_t': 'uint16', 'uint32_t': 'uint32', 'uint64_t': 'uint64',
    'int_least8_t': 'int8', 'int_least16_t': 'int16', 'int_least32_t': 'int32', 'int_least64_t': 'int64',
    'uint_least8_t': 'uint8', 'uint_least16_t': 'uint16', 'uint_least32_t': 'uint32', 'uint_least64_t': 'uint64',
    'intmax_t': 'int64', 'uintmax_t': 'uint64',
    'va_list': 'cvalist', '__builtin_va_list': 'cvalist', '__gnuc_va_list': 'cvalist',
    'wchar_t': 'cwchar_t', 'clock_t': 'cclock_t', 'time_t': 'ctime_t',
    '_Bool': 'boolean',
}


C_SIMPLE_ESCAPES = {
    'n': '\n', 't': '\t', 'r': '\r', 'a': '\a', 'b': '\b', 'f': '\f', 'v': '\v', 'e': '\x1b',
    '\\': '\\', "'": "'", '"': '"', '?': '?',
}
HEX_DIGITS = '0123456789abcdefABCDEF'


def decode_c_string(tok):
    """Decode a plain C string literal token (`"..."`) to bytes; None when it is not one."""
    if len(tok) < 2 or tok[0] != '"' or tok[-1] != '"':
        return None
    s, out, i = tok[1:-1], bytearray(), 0
    while i < len(s):
        ch = s[i]
        if ch != '\\':
            out += ch.encode('utf-8')
            i += 1
            continue
        i += 1
        if i >= len(s):
            return None
        ch = s[i]
        if ch in C_SIMPLE_ESCAPES:
            out += C_SIMPLE_ESCAPES[ch].encode('utf-8')
            i += 1
        elif ch in '01234567':
            j = i
            while j < len(s) and j < i + 3 and s[j] in '01234567':
                j += 1
            out.append(int(s[i:j], 8) & 0xff)
            i = j
        elif ch == 'x':
            j = i + 1
            while j < len(s) and s[j] in HEX_DIGITS:
                j += 1
            if j == i + 1:
                return None
            out.append(int(s[i + 1:j], 16) & 0xff)
            i = j
        elif ch in 'uU':
            n = 4 if ch == 'u' else 8
            digits = s[i + 1:i + 1 + n]
            if len(digits) != n or any(d not in HEX_DIGITS for d in digits):
                return None
            out += chr(int(digits, 16)).encode('utf-8')
            i += 1 + n
        else:
            return None
    return bytes(out)


def nelua_string(data):
    """Spell bytes as a double quoted Nelua string literal (printable ASCII verbatim, the rest as \\xHH)."""
    parts = []
    for byte in data:
        if byte == 0x22:
            parts.append('\\"')
        elif byte == 0x5c:
            parts.append('\\\\')
        elif byte == 0x0a:
            parts.append('\\n')
        elif byte == 0x09:
            parts.append('\\t')
        elif byte == 0x0d:
            parts.append('\\r')
        elif 0x20 <= byte < 0x7f:
            parts.append(chr(byte))
        else:
            parts.append('\\x%02X' % byte)
    return '"%s"' % ''.join(parts)


def nelua_ident(name, used=None):
    """Make `name` a valid Nelua identifier, avoiding keywords (and `used` names)."""
    if not name:
        return name
    name = re.sub(r'[^A-Za-z0-9_]', '_', name)
    if name[0].isdigit():
        name = '_' + name
    if name in NELUA_KEYWORDS:
        name = name + '_'
    if used is not None:
        base, i = name, 1
        while name in used:
            i += 1
            name = '%s_%d' % (base, i)
    return name


class Generator:
    def __init__(self, args):
        self.args = args
        self.out = []
        self.defined = {}        # nelua name -> kind, for emitted type declarations
        self.names_used = set()  # every emitted global name
        self.tag_names = {}      # (kind, C tag or typedef name) -> nelua name
        self.referenced = {}     # nelua name -> C declaration cursor, for stubs
        self.forwarded = set()   # nelua names emitted as forwarddecl
        self.comptime = {}       # C macro/enumerator name -> nelua expression, for alias macros
        self.deferred_macros = []  # alias macros whose target was not emitted yet
        self.skipped = []
        self.notes = []          # declarations bound differently than an option asked for
        self.excludes = [re.compile(x) for x in args.exclude]
        self.opaque = set(args.opaque)
        self.nullable_returns = [re.compile(x) for x in args.nullable_returns]
        self.nullable_wrapped = False  # a `*T?` wrapper was emitted, the output needs `require 'optional'`
        self.header_index = None       # index in `out` after which `require 'optional'` is inserted
        self.opaque_usrs = set()  # USRs of record declarations named (by tag or typedef) in --opaque
        self.prefix = (args.prefix + '.') if args.prefix else ''
        self.inputs = [os.path.abspath(h) for h in args.headers]

    # -- helpers -------------------------------------------------------------

    def cinclude(self, cursor):
        if self.args.include_as:
            return self.args.include_as
        f = cursor.location.file
        name = os.path.basename(f.name) if f else os.path.basename(self.inputs[0])
        return '"%s"' % name

    def annots(self, cursor, *extra, cimport=None):
        parts = ["cimport'%s'" % cimport if cimport else 'cimport', "cinclude'%s'" % self.cinclude(cursor)]
        parts.extend(e for e in extra if e)
        return '<%s>' % ','.join(parts)

    def emit(self, line=''):
        self.out.append(line)

    def in_inputs(self, cursor):
        f = cursor.location.file
        if f is None:
            return False
        if self.args.all:
            return True
        path = os.path.abspath(f.name)
        if path in self.inputs:
            return True
        return bool(self.args.include_file_regex and re.search(self.args.include_file_regex, path))

    def wanted(self, name):
        if self.args.match and not re.search(self.args.match, name):
            return False
        return not any(x.search(name) for x in self.excludes)

    def is_opaque(self, decl, name):
        return name in self.opaque or (decl.spelling and decl.spelling in self.opaque) or decl.get_usr() in self.opaque_usrs

    def is_opaque_name(self, name):
        """True while `name` is only known as a forwarddecl record, so it cannot be used by value."""
        return name in self.forwarded and name not in self.defined

    def collect_opaque(self, cursor):
        """Pre-pass: `--opaque foo_t` on `typedef struct foo {...} foo_t` makes the tag `foo` opaque too,
        so the record is forward declared once and the typedef becomes an alias of it (one Nelua type)."""
        if not self.opaque:
            return
        for c in cursor.get_children():
            if not self.in_inputs(c):
                continue
            if c.kind == CursorKind.TYPEDEF_DECL and c.spelling in self.opaque:
                under = c.underlying_typedef_type
                named = under.get_named_type() if under.kind == TypeKind.ELABORATED else under
                decl = named.get_declaration()
                if named.kind == TypeKind.RECORD and decl.kind != CursorKind.NO_DECL_FOUND:
                    self.opaque_usrs.add(decl.get_usr())
            elif c.kind in (CursorKind.STRUCT_DECL, CursorKind.UNION_DECL) and c.spelling in self.opaque:
                self.opaque_usrs.add(c.get_usr())

    def skip(self, cursor, why):
        self.skipped.append('%s (%s) skipped: %s' % (cursor.spelling or '<anonymous>', cursor.kind.name.lower(), why))

    # -- types ---------------------------------------------------------------

    def record_name(self, decl):
        """Nelua name for a struct/union/enum declaration cursor."""
        key = (decl.kind, decl.get_usr())
        if key in self.tag_names:
            return self.tag_names[key]
        name = decl.spelling
        if not name or decl.is_anonymous():
            return None
        nelua = nelua_ident(name)
        self.tag_names[key] = nelua
        return nelua

    def type_str(self, t, depth=0, inptr=False):
        """Map a clang type to Nelua type syntax.

        `inptr` is true below a pointer (or when aliasing a type), where an opaque record is fine;
        a by-value use of a record that is only forward declared raises ValueError, since Nelua
        rejects forwarddecl types in fields, parameters, returns and variables."""
        kind = t.kind
        if kind in PRIM_KINDS:
            return PRIM_KINDS[kind]
        if kind == TypeKind.TYPEDEF:
            name = t.get_declaration().spelling
            if name in PRIM_TYPEDEFS:
                return PRIM_TYPEDEFS[name]
            decl = t.get_declaration()
            nelua = nelua_ident(name)
            if nelua in self.defined or (self.in_inputs(decl) and self.wanted(name)):
                if not inptr and self.is_opaque_name(nelua):
                    raise ValueError("opaque record '%s' used by value" % nelua)
                return self.prefix + nelua
            # typedef from another header, or excluded: resolve it structurally unless it names a record
            under = t.get_canonical()
            if under.kind == TypeKind.RECORD:
                self.referenced.setdefault(nelua, decl)
                return self.prefix + nelua
            return self.type_str(under, depth, inptr)
        if kind == TypeKind.ELABORATED:
            return self.type_str(t.get_named_type(), depth, inptr)
        if kind == TypeKind.POINTER:
            pointee = t.get_pointee()
            const = 'const ' if pointee.is_const_qualified() else ''
            pk = pointee.kind
            if pk == TypeKind.ELABORATED:
                pointee = pointee.get_named_type()
                pk = pointee.kind
            if pk in (TypeKind.FUNCTIONPROTO, TypeKind.FUNCTIONNOPROTO):
                return self.func_type_str(pointee)
            if pk == TypeKind.VOID:
                return '*const void' if const else 'pointer'
            if pk in (TypeKind.CHAR_S, TypeKind.CHAR_U):
                return '*const cchar' if const else 'cstring'
            return '*%s%s' % (const, self.type_str(pointee, depth + 1, True))
        if kind == TypeKind.CONSTANTARRAY:
            return '[%d]%s' % (t.element_count, self.type_str(t.element_type, depth + 1, inptr))
        if kind == TypeKind.INCOMPLETEARRAY:
            return '[0]%s' % self.type_str(t.element_type, depth + 1, inptr)
        if kind in (TypeKind.FUNCTIONPROTO, TypeKind.FUNCTIONNOPROTO):
            return self.func_type_str(t)
        if kind == TypeKind.RECORD:
            decl = t.get_declaration()
            name = self.record_name(decl)
            if name is None:
                return self.inline_record(decl, depth)
            if name not in self.defined:
                # other header, excluded, or not emitted yet: a stub is written at the end if still undefined
                self.referenced.setdefault(name, decl)
            if not inptr and self.is_opaque_name(name):
                raise ValueError("opaque record '%s' used by value" % name)
            return self.prefix + name
        if kind == TypeKind.ENUM:
            decl = t.get_declaration()
            name = self.record_name(decl)
            if name is None or (name not in self.defined and not (self.in_inputs(decl) and self.wanted(decl.spelling))):
                return self.type_str(decl.enum_type, depth)
            return self.prefix + name
        if kind == TypeKind.UNEXPOSED:
            return self.type_str(t.get_canonical(), depth, inptr)
        if kind == TypeKind.ATOMIC:
            return self.type_str(t.get_canonical(), depth, inptr)
        raise ValueError('unsupported C type kind %s (%s)' % (kind.name, t.spelling))

    def param_type_str(self, t):
        """Parameter types: C decays `T a[N]` to `T*`, which Nelua spells `*[0]T`."""
        named = t.get_named_type() if t.kind == TypeKind.ELABORATED else t
        if named.kind in (TypeKind.CONSTANTARRAY, TypeKind.INCOMPLETEARRAY):
            elem = named.element_type
            const = 'const ' if elem.is_const_qualified() else ''
            return '*%s[0]%s' % (const, self.type_str(elem, 0, True))
        return self.type_str(t)

    def func_type_str(self, t):
        args = [self.param_type_str(a) for a in t.argument_types()] if t.kind == TypeKind.FUNCTIONPROTO else []
        if t.kind == TypeKind.FUNCTIONPROTO and t.is_function_variadic():
            args.append('cvarargs')
        ret = self.type_str(t.get_result())
        return 'function(%s)%s' % (', '.join(args), (': ' + ret) if ret != 'void' else '')

    def fields(self, decl, depth):
        lines = []
        incomplete = False
        for f in decl.get_children():
            if f.kind == CursorKind.FIELD_DECL:
                if f.is_bitfield():
                    incomplete = True
                    lines.append('-- bitfield `%s` omitted' % f.spelling)
                    continue
                try:
                    tstr = self.type_str(f.type, depth + 1)
                except ValueError as e:
                    incomplete = True
                    lines.append('-- field `%s` omitted: %s' % (f.spelling, e))
                    continue
                lines.append('%s: %s,' % (nelua_ident(f.spelling), tstr))
            elif f.kind in (CursorKind.STRUCT_DECL, CursorKind.UNION_DECL) and f.is_anonymous():
                # anonymous member without a field name: C11 anonymous struct/union
                if not any(c.kind == CursorKind.FIELD_DECL and c.type.get_declaration() == f for c in decl.get_children()):
                    incomplete = True
                    lines.append('-- anonymous %s member omitted' % f.kind.name.split('_')[0].lower())
        return lines, incomplete

    def inline_record(self, decl, depth):
        kw = 'union' if decl.kind == CursorKind.UNION_DECL else 'record'
        lines, _ = self.fields(decl, depth)
        return '%s{%s}' % (kw, ' '.join(lines))

    # -- declarations --------------------------------------------------------

    def ctypedef_annot(self, decl, name):
        """`ctypedef'tag'` makes Nelua emit `typedef struct tag <codename>;`: only when the C type has a
        tag (a tagless `typedef struct {...} name` would clash with the header's own typedef), and always
        spelled out, since a `<cimport>` alias of the record renames its codename to the alias."""
        tag = decl.spelling if decl.spelling and not decl.is_anonymous() else ''
        return "ctypedef'%s'" % tag if tag else ''

    def emit_record(self, decl, typedef_name=None):
        name = typedef_name or self.record_name(decl)
        if name is None:
            return
        kw = 'union' if decl.kind == CursorKind.UNION_DECL else 'record'
        ctypedef = self.ctypedef_annot(decl, name)
        defined = decl.is_definition() and not self.is_opaque(decl, name)
        if not defined:
            if name in self.defined or name in self.forwarded:
                return
            # forward declaration: define opaque now, completed later if the definition shows up
            self.forwarded.add(name)
            self.names_used.add(name)
            self.emit('global %s%s: type %s = @%s{}' % (self.prefix, name, self.annots(decl, ctypedef, 'forwarddecl'), kw))
            return
        if name in self.defined:
            return
        lines, incomplete = self.fields(decl, 0)
        annots = self.annots(decl, ctypedef, 'cincomplete' if incomplete else '')
        body = '@%s{\n  %s\n}' % (kw, '\n  '.join(lines)) if lines else '@%s{}' % kw
        if name in self.forwarded:
            if self.is_opaque(decl, name):
                return
            self.emit('%s%s = %s' % (self.prefix, name, body))
        else:
            self.emit('global %s%s: type %s = %s' % (self.prefix, name, annots, body))
        self.defined[name] = kw
        self.names_used.add(name)

    def emit_enum(self, decl, typedef_name=None):
        name = typedef_name or self.record_name(decl)
        inttype = self.type_str(decl.enum_type)
        items = ['%s = %d,' % (nelua_ident(c.spelling), c.enum_value) for c in decl.get_children()
                 if c.kind == CursorKind.ENUM_CONSTANT_DECL]
        if name is None:
            # anonymous enum: plain compile time constants
            for c in decl.get_children():
                if c.kind == CursorKind.ENUM_CONSTANT_DECL and self.wanted(c.spelling):
                    cname = nelua_ident(c.spelling)
                    self.emit('global %s%s: %s <comptime> = %d' % (self.prefix, cname, inttype, c.enum_value))
                    self.names_used.add(cname)
                    self.comptime[c.spelling] = self.prefix + cname
            return
        if name in self.defined:
            return
        ctypedef = self.ctypedef_annot(decl, name)
        using = 'using' if self.args.enum_using else ''
        self.emit('global %s%s: type %s = @enum(%s){\n  %s\n}' % (
            self.prefix, name, self.annots(decl, ctypedef, using), inttype, '\n  '.join(items)))
        self.defined[name] = 'enum'
        self.names_used.add(name)
        for c in decl.get_children():
            if c.kind == CursorKind.ENUM_CONSTANT_DECL:
                self.comptime[c.spelling] = '%s%s.%s' % (self.prefix, name, nelua_ident(c.spelling))

    def emit_typedef(self, cursor):
        name = cursor.spelling
        if name in PRIM_TYPEDEFS or not self.wanted(name):
            return
        under = cursor.underlying_typedef_type
        named = under.get_named_type() if under.kind == TypeKind.ELABORATED else under
        decl = named.get_declaration()
        nname = nelua_ident(name)
        if name in self.opaque and not (named.kind == TypeKind.RECORD and decl.kind != CursorKind.NO_DECL_FOUND):
            if nname in self.forwarded or nname in self.defined:
                return
            self.forwarded.add(nname)
            self.names_used.add(nname)
            self.emit('global %s%s: type %s = @record{}' % (self.prefix, nname, self.annots(cursor, 'forwarddecl')))
            return
        if named.kind == TypeKind.RECORD and decl.kind != CursorKind.NO_DECL_FOUND:
            tag = decl.spelling
            if not tag or decl.is_anonymous() or tag == name:
                self.emit_record(decl, nelua_ident(name))
                return
            tagname = self.record_name(decl)
            if tagname not in self.defined and tagname not in self.forwarded and self.is_opaque(decl, name) \
                    and self.wanted(tag):
                # `--opaque foo_t` on `typedef struct foo ... foo_t`: forward declare the tag, alias the typedef
                self.emit_record(decl)
            if tagname in self.defined or tagname in self.forwarded:
                self.emit('global %s%s: type <cimport,cinclude\'%s\',nodecl> = @%s%s' % (
                    self.prefix, nelua_ident(name), self.cinclude(cursor), self.prefix, tagname))
                self.defined[nelua_ident(name)] = 'alias'
                return
            self.emit_record(decl, nelua_ident(name))
            self.tag_names[(decl.kind, decl.get_usr())] = nelua_ident(name)
            return
        if named.kind == TypeKind.ENUM and decl.kind != CursorKind.NO_DECL_FOUND:
            if not decl.spelling or decl.is_anonymous() or decl.spelling == name:
                self.emit_enum(decl, nelua_ident(name))
                self.tag_names[(decl.kind, decl.get_usr())] = nelua_ident(name)
                return
        try:
            tstr = self.type_str(under, 0, True)
        except ValueError as e:
            self.skip(cursor, str(e))
            return
        self.emit('global %s%s: type <cimport,cinclude\'%s\',nodecl> = @%s' % (self.prefix, nname, self.cinclude(cursor), tstr))
        self.defined[nname] = 'alias'
        self.names_used.add(nname)

    def emit_function(self, cursor):
        name = cursor.spelling
        if not self.wanted(name) or name in self.names_used:
            return
        if cursor.is_static_method() if hasattr(cursor, 'is_static_method') else False:
            return
        params = []
        used = set()
        for i, p in enumerate(cursor.get_arguments()):
            pname = nelua_ident(p.spelling or 'a%d' % (i + 1), used)
            used.add(pname)
            try:
                params.append('%s: %s' % (pname, self.param_type_str(p.type)))
            except ValueError as e:
                self.skip(cursor, str(e))
                return
        if cursor.type.kind == TypeKind.FUNCTIONPROTO and cursor.type.is_function_variadic():
            params.append('...: cvarargs')
        try:
            ret = self.type_str(cursor.result_type)
        except ValueError as e:
            self.skip(cursor, str(e))
            return
        rets = (': ' + ret) if ret != 'void' else ''
        # a record field is declared `function C.name(...)`; `global function C.name` is not Nelua
        head = 'function %s%s' % (self.prefix, nelua_ident(name)) if self.prefix else 'global function %s' % nelua_ident(name)
        if self.is_nullable_return(cursor, name, params):
            # `--nullable-returns`: bind the C prototype unchanged under a hidden name and expose an inline
            # wrapper whose Nelua return type is the optional pointer `*T?` (`nilptr` converts to empty)
            hidden = nelua_ident(name) + '__c'
            self.emit('local function %s(%s)%s %s end' % (hidden, ', '.join(params), rets, self.annots(cursor, cimport=name)))
            optret = ret
            if 'function(' in ret:
                # `?` binds to the result of an inline function type (`function(cint): cint?` returns `cint?`)
                # and types take no parentheses, so the return type is named first
                optret = nelua_ident(name) + '__ret'
                self.emit('local %s: type = @%s' % (optret, ret))
            self.emit('%s(%s): %s? <inline> return %s(%s) end' % (
                head, ', '.join(params), optret, hidden, ', '.join(p.split(':', 1)[0] for p in params)))
            self.nullable_wrapped = True
        else:
            self.emit('%s(%s)%s %s end' % (head, ', '.join(params), rets, self.annots(cursor)))
        self.names_used.add(name)

    def is_nullable_return(self, cursor, name, params):
        """Whether `--nullable-returns` asks for a `*T?` wrapper: a pointer returning, non variadic function
        whose name matches one of the patterns (a variadic function cannot forward its arguments)."""
        if not any(x.search(name) for x in self.nullable_returns):
            return False
        if cursor.result_type.get_canonical().kind != TypeKind.POINTER:
            self.notes.append('%s: --nullable-returns matched but it does not return a pointer, bound as is' % name)
            return False
        if params and params[-1] == '...: cvarargs':
            self.notes.append('%s: --nullable-returns matched but it is variadic, bound as is' % name)
            return False
        return True

    def emit_variable(self, cursor):
        name = cursor.spelling
        if not self.wanted(name) or name in self.names_used:
            return
        try:
            tstr = self.type_str(cursor.type)
        except ValueError as e:
            self.skip(cursor, str(e))
            return
        self.emit('global %s%s: %s %s' % (self.prefix, nelua_ident(name), tstr, self.annots(cursor)))
        self.names_used.add(name)

    MACRO_INT = re.compile(r'^(?:\(\s*)?([+-]?(?:0[xX][0-9a-fA-F]+|0[bB][01]+|[0-9]+))([uUlL]*)(?:\s*\))?$')
    MACRO_FLOAT = re.compile(r'^(?:\(\s*)?([+-]?(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[eE][+-]?[0-9]+)?)([fFlL]?)(?:\s*\))?$')

    def emit_macro(self, cursor):
        name = cursor.spelling
        if not self.wanted(name) or name in self.names_used or name.startswith('_'):
            return
        toks = [t.spelling for t in cursor.get_tokens()]
        if len(toks) < 2 or toks[0] != name:
            return
        if toks[1] == '(' and cursor.extent.start.column + len(name) == cursor.location.column + len(name) and \
                any(t == ')' for t in toks) and self._is_function_like(cursor, toks):
            self.skip(cursor, 'function-like macro')
            return
        body = ''.join(toks[1:])
        m = self.MACRO_INT.match(body)
        if m:
            value, suffix = m.group(1), m.group(2).lower()
            if value.lower().startswith('0b'):
                value = str(int(value, 2))
            ctype = 'cint'
            if 'u' in suffix and 'll' in suffix:
                ctype = 'culonglong'
            elif 'll' in suffix:
                ctype = 'clonglong'
            elif 'u' in suffix and 'l' in suffix:
                ctype = 'culong'
            elif 'l' in suffix:
                ctype = 'clong'
            elif 'u' in suffix:
                ctype = 'cuint'
            self.emit_comptime(name, ctype, value)
            return
        m = self.MACRO_FLOAT.match(body)
        if m:
            value, suffix = m.group(1), m.group(2).lower()
            ctype = 'float32' if suffix == 'f' else ('clongdouble' if suffix == 'l' else 'float64')
            self.emit_comptime(name, ctype, value)
            return
        if all(t.startswith('"') for t in toks[1:]):
            # one or more adjacent plain string literals: decode the C spelling, respell it for Nelua
            pieces = [decode_c_string(t) for t in toks[1:]]
            if all(p is not None for p in pieces):
                self.emit_comptime(name, 'cstring', nelua_string(b''.join(pieces)))
                return
        if len(toks) == 2 and re.match(r'^[A-Za-z_][A-Za-z0-9_]*$', toks[1]):
            if toks[1] in self.comptime:
                self.emit_alias_macro(name, toks[1])
            else:
                self.deferred_macros.append((cursor, toks[1]))
            return
        self.skip(cursor, 'macro body is not a literal: %s' % ' '.join(toks[1:])[:60])

    def emit_comptime(self, name, ctype, value):
        self.emit('global %s%s: %s <comptime> = %s' % (self.prefix, nelua_ident(name), ctype, value))
        self.names_used.add(name)
        self.comptime[name] = self.prefix + nelua_ident(name)

    def emit_alias_macro(self, name, target):
        self.emit('global %s%s <comptime> = %s' % (self.prefix, nelua_ident(name), self.comptime[target]))
        self.names_used.add(name)
        self.comptime[name] = self.prefix + nelua_ident(name)

    def emit_deferred_macros(self):
        """Alias macros whose target was not emitted yet, iterated to a fixpoint so `#define A B` /
        `#define B C` / `#define C 1` in source order emits all three; the rest are listed as skipped."""
        pending = self.deferred_macros
        while pending:
            rest = []
            for cursor, target in pending:
                if target in self.comptime:
                    self.emit_alias_macro(cursor.spelling, target)
                else:
                    rest.append((cursor, target))
            if len(rest) == len(pending):
                break
            pending = rest
        for cursor, target in pending:
            self.skip(cursor, 'macro body is not a literal: %s' % target)

    @staticmethod
    def _is_function_like(cursor, toks):
        # a function-like macro has `(` immediately after its name with no whitespace
        tokens = list(cursor.get_tokens())
        if len(tokens) < 2:
            return False
        first, second = tokens[0], tokens[1]
        return second.spelling == '(' and second.extent.start.offset == first.extent.end.offset

    # -- driver --------------------------------------------------------------

    def visit(self, cursor):
        for c in cursor.get_children():
            if not self.in_inputs(c):
                continue
            k = c.kind
            try:
                if k == CursorKind.FUNCTION_DECL:
                    self.emit_function(c)
                elif k == CursorKind.VAR_DECL:
                    self.emit_variable(c)
                elif k == CursorKind.TYPEDEF_DECL:
                    self.emit_typedef(c)
                elif k in (CursorKind.STRUCT_DECL, CursorKind.UNION_DECL):
                    if c.spelling and not c.is_anonymous() and self.wanted(c.spelling):
                        self.emit_record(c)
                elif k == CursorKind.ENUM_DECL:
                    if (not c.spelling or c.is_anonymous()) or self.wanted(c.spelling):
                        self.emit_enum(c)
                elif k == CursorKind.MACRO_DEFINITION:
                    self.emit_macro(c)
            except ValueError as e:
                self.skip(c, str(e))

    def run(self):
        index = cindex.Index.create()
        clang_args = ['-x', 'c'] + ['-I' + d for d in self.args.include_dirs] + ['-D' + d for d in self.args.defines]
        if self.args.target:
            clang_args += ['-target', self.args.target]
        clang_args += self.args.clang_args
        opts = cindex.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD | cindex.TranslationUnit.PARSE_SKIP_FUNCTION_BODIES
        wrapper = ''.join('#include "%s"\n' % h for h in self.inputs)
        tu = index.parse('nelua-bindgen-input.c', clang_args, unsaved_files=[('nelua-bindgen-input.c', wrapper)], options=opts)
        errors = [d for d in tu.diagnostics if d.severity >= cindex.Diagnostic.Error]
        for d in errors:
            sys.stderr.write('nelua-bindgen: %s\n' % d)
        if errors and not self.args.ignore_errors:
            sys.exit(1)
        self.emit('-- Generated by nelua-bindgen from %s. Do not edit by hand.' % ', '.join(os.path.basename(h) for h in self.inputs))
        if self.args.prefix:
            self.emit('global %s = @record{}' % self.args.prefix)
        self.header_index = len(self.out)
        self.emit()
        if self.args.prepend:
            self.emit(self.args.prepend.rstrip('\n'))
            self.emit()
        self.collect_opaque(tu.cursor)
        head, self.out = self.out, []
        self.visit(tu.cursor)
        self.emit_deferred_macros()
        body, self.out = self.out, head
        if not self.args.no_stubs:
            # stubs go before the declarations that reference them: Nelua resolves names in source order
            stubs = [(n, d) for n, d in self.referenced.items() if n not in self.defined and n not in self.forwarded]
            if stubs:
                self.emit('-- Opaque stubs for types declared in other headers or excluded; replace with real bindings when needed.')
                for n, d in stubs:
                    kw = 'union' if d.kind == CursorKind.UNION_DECL else 'record'
                    if d.kind == CursorKind.ENUM_DECL:
                        continue
                    ctypedef = "ctypedef'%s'" % d.spelling if d.kind != CursorKind.TYPEDEF_DECL and d.spelling else ''
                    self.emit('global %s%s: type %s = @%s{}' % (self.prefix, n, self.annots(d, ctypedef, 'cincomplete'), kw))
                self.emit()
        self.out.extend(body)
        if self.skipped:
            self.emit()
            self.emit('-- Not generated:')
            for s in self.skipped:
                self.emit('--   ' + s)
        if self.notes:
            self.emit()
            self.emit('-- Notes:')
            for s in self.notes:
                self.emit('--   ' + s)
        if self.args.append:
            self.emit()
            self.emit(self.args.append.rstrip('\n'))
        if self.nullable_wrapped:
            self.out.insert(self.header_index, "require 'optional'")
        return '\n'.join(self.out) + '\n'


# Config file keys: value kind, and whether paths in them resolve relative to the config file.
CONFIG_KEYS = {
    'headers': ('pathlist', True), 'include_dirs': ('pathlist', True), 'defines': ('list', False),
    'target': ('str', False), 'include_as': ('str', False), 'prefix': ('str', False), 'match': ('str', False),
    'exclude': ('list', False), 'opaque': ('list', False), 'nullable_returns': ('list', False),
    'enum_using': ('bool', False), 'all': ('bool', False),
    'include_file_regex': ('str', False), 'no_stubs': ('bool', False), 'prepend': ('text', False),
    'append': ('text', False), 'output': ('str', True),
}


def load_config(path, args):
    """Fill options not given on the command line from the JSON object in `path`."""
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise SystemExit('nelua-bindgen: %s: config must be a JSON object' % path)
    base = os.path.dirname(os.path.abspath(path))
    for key, value in cfg.items():
        if key not in CONFIG_KEYS:
            raise SystemExit('nelua-bindgen: %s: unknown config key %r (known: %s)' % (path, key, ', '.join(sorted(CONFIG_KEYS))))
        kind, relative = CONFIG_KEYS[key]
        if kind in ('list', 'pathlist'):
            if isinstance(value, str):
                value = [value]
            if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
                raise SystemExit('nelua-bindgen: %s: %r must be a string or a list of strings' % (path, key))
        elif kind == 'text':
            if isinstance(value, list):
                value = '\n'.join(value)
            if not isinstance(value, str):
                raise SystemExit('nelua-bindgen: %s: %r must be a string or a list of lines' % (path, key))
        elif kind == 'bool':
            if not isinstance(value, bool):
                raise SystemExit('nelua-bindgen: %s: %r must be true or false' % (path, key))
        elif not isinstance(value, str):
            raise SystemExit('nelua-bindgen: %s: %r must be a string' % (path, key))
        if relative:
            if kind == 'pathlist':
                value = [v if os.path.isabs(v) else os.path.join(base, v) for v in value]
            elif not os.path.isabs(value):
                value = os.path.join(base, value)
        current = getattr(args, key)
        if current is None or current == [] or current is False:
            setattr(args, key, value)


def main(argv=None):
    ap = argparse.ArgumentParser(description='Generate Nelua bindings from C headers with libclang.')
    ap.add_argument('headers', nargs='*', help='C header files to bind')
    ap.add_argument('-I', dest='include_dirs', action='append', default=[], help='include search directory')
    ap.add_argument('-D', dest='defines', action='append', default=[], help='preprocessor define')
    ap.add_argument('--target', help='clang target triple used to parse the headers')
    ap.add_argument('--include-as', help="cinclude spec written into every binding, e.g. '<zlib.h>' (default: \"basename.h\")")
    ap.add_argument('--prefix', help='emit declarations as fields of this global record (e.g. C)')
    ap.add_argument('--match', help='only bind declarations whose name matches this regex')
    ap.add_argument('--exclude', action='append', default=[], help='skip declarations whose name matches this regex (repeatable)')
    ap.add_argument('--opaque', action='append', default=[], help='emit this record or typedef as an opaque forwarddecl record (repeatable)')
    ap.add_argument('--nullable-returns', action='append', default=[], help='wrap pointer returning functions whose name matches this regex so they return `*T?` (repeatable)')
    ap.add_argument('--enum-using', action='store_true', help='mark named enums <using> so enumerators are also bare globals')
    ap.add_argument('--all', action='store_true', help='also bind declarations from transitively included headers')
    ap.add_argument('--include-file-regex', help='also bind declarations from included files matching this regex')
    ap.add_argument('--no-stubs', action='store_true', help='do not emit opaque stubs for types from other headers')
    ap.add_argument('--prepend', help='verbatim Nelua text written before the generated declarations')
    ap.add_argument('--append', help='verbatim Nelua text written after the generated declarations')
    ap.add_argument('--config', help='JSON file whose keys mirror these options; command-line options override it')
    ap.add_argument('--ignore-errors', action='store_true', help='generate even when clang reports errors')
    ap.add_argument('--libclang', help='path to libclang shared library')
    ap.add_argument('-o', '--output', help='output file (default: stdout)')
    ap.add_argument('clang_args', nargs='*', help='extra arguments after -- are passed to clang')
    args = ap.parse_args(argv)
    if args.config:
        load_config(args.config, args)
    if not args.headers:
        ap.error('no headers given (on the command line or as "headers" in --config)')
    if args.libclang:
        cindex.Config.set_library_file(args.libclang)
    code = Generator(args).run()
    if args.output:
        with open(args.output, 'w') as f:
            f.write(code)
    else:
        sys.stdout.write(code)
    return 0


if __name__ == '__main__':
    sys.exit(main())
