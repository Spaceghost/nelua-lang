#!/usr/bin/env python3
"""nelua-bindgen: generate Nelua `<cimport>` bindings from C headers using libclang.

Usage:
  nelua-bindgen.py header.h [header2.h ...] [-I dir] [-D name[=value]] [--include-as '<zlib.h>']
                   [--prefix NS] [--match REGEX] [--all] [--no-stubs] [-o out.nelua]

Requires the libclang Python bindings (Debian/Ubuntu: `apt install python3-clang`).
"""
import argparse
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
        self.skipped = []
        self.prefix = (args.prefix + '.') if args.prefix else ''
        self.inputs = [os.path.abspath(h) for h in args.headers]

    # -- helpers -------------------------------------------------------------

    def cinclude(self, cursor):
        if self.args.include_as:
            return self.args.include_as
        f = cursor.location.file
        name = os.path.basename(f.name) if f else os.path.basename(self.inputs[0])
        return '"%s"' % name

    def annots(self, cursor, *extra):
        parts = ['cimport', "cinclude'%s'" % self.cinclude(cursor)]
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
        return not self.args.match or re.search(self.args.match, name)

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

    def type_str(self, t, depth=0):
        """Map a clang type to Nelua type syntax."""
        kind = t.kind
        if kind in PRIM_KINDS:
            return PRIM_KINDS[kind]
        if kind == TypeKind.TYPEDEF:
            name = t.get_declaration().spelling
            if name in PRIM_TYPEDEFS:
                return PRIM_TYPEDEFS[name]
            decl = t.get_declaration()
            nelua = nelua_ident(name)
            if self.in_inputs(decl) or nelua in self.defined:
                return self.prefix + nelua
            # typedef from another header: resolve it structurally unless it names a record
            under = t.get_canonical()
            if under.kind in (TypeKind.RECORD, TypeKind.ENUM):
                self.referenced.setdefault(nelua, decl)
                return self.prefix + nelua
            return self.type_str(under, depth)
        if kind == TypeKind.ELABORATED:
            return self.type_str(t.get_named_type(), depth)
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
            return '*%s%s' % (const, self.type_str(pointee, depth + 1))
        if kind == TypeKind.CONSTANTARRAY:
            return '[%d]%s' % (t.element_count, self.type_str(t.element_type, depth + 1))
        if kind == TypeKind.INCOMPLETEARRAY:
            return '[0]%s' % self.type_str(t.element_type, depth + 1)
        if kind in (TypeKind.FUNCTIONPROTO, TypeKind.FUNCTIONNOPROTO):
            return self.func_type_str(t)
        if kind == TypeKind.RECORD:
            decl = t.get_declaration()
            name = self.record_name(decl)
            if name is None:
                return self.inline_record(decl, depth)
            if not self.in_inputs(decl) and name not in self.defined:
                self.referenced.setdefault(name, decl)
            return self.prefix + name
        if kind == TypeKind.ENUM:
            decl = t.get_declaration()
            name = self.record_name(decl)
            if name is None or (not self.in_inputs(decl) and name not in self.defined):
                return self.type_str(decl.enum_type, depth)
            return self.prefix + name
        if kind == TypeKind.UNEXPOSED:
            return self.type_str(t.get_canonical(), depth)
        if kind == TypeKind.ATOMIC:
            return self.type_str(t.get_canonical(), depth)
        raise ValueError('unsupported C type kind %s (%s)' % (kind.name, t.spelling))

    def param_type_str(self, t):
        """Parameter types: C decays `T a[N]` to `T*`, which Nelua spells `*[0]T`."""
        named = t.get_named_type() if t.kind == TypeKind.ELABORATED else t
        if named.kind in (TypeKind.CONSTANTARRAY, TypeKind.INCOMPLETEARRAY):
            elem = named.element_type
            const = 'const ' if elem.is_const_qualified() else ''
            return '*%s[0]%s' % (const, self.type_str(elem))
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

    def emit_record(self, decl, typedef_name=None):
        name = typedef_name or self.record_name(decl)
        if name is None:
            return
        kw = 'union' if decl.kind == CursorKind.UNION_DECL else 'record'
        defined = decl.is_definition()
        if not defined:
            if name in self.defined or name in self.forwarded:
                return
            # forward declaration: define opaque now, completed later if the definition shows up
            self.forwarded.add(name)
            self.names_used.add(name)
            ctypedef = '' if typedef_name else "ctypedef'%s'" % decl.spelling
            self.emit('global %s%s: type %s = @%s{}' % (self.prefix, name, self.annots(decl, ctypedef, 'forwarddecl'), kw))
            return
        if name in self.defined:
            return
        lines, incomplete = self.fields(decl, 0)
        ctypedef = 'ctypedef' if typedef_name or True else ''
        if not typedef_name:
            # plain `struct tag` without typedef: ask Nelua to emit `typedef struct tag tag;`
            ctypedef = "ctypedef'%s'" % decl.spelling
        annots = self.annots(decl, ctypedef, 'cincomplete' if incomplete else '')
        body = '@%s{\n  %s\n}' % (kw, '\n  '.join(lines)) if lines else '@%s{}' % kw
        if name in self.forwarded:
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
            return
        if name in self.defined:
            return
        ctypedef = 'ctypedef' if typedef_name else "ctypedef'%s'" % decl.spelling
        self.emit('global %s%s: type %s = @enum(%s){\n  %s\n}' % (
            self.prefix, name, self.annots(decl, ctypedef), inttype, '\n  '.join(items)))
        self.defined[name] = 'enum'
        self.names_used.add(name)

    def emit_typedef(self, cursor):
        name = cursor.spelling
        if name in PRIM_TYPEDEFS or not self.wanted(name):
            return
        under = cursor.underlying_typedef_type
        named = under.get_named_type() if under.kind == TypeKind.ELABORATED else under
        decl = named.get_declaration()
        if named.kind == TypeKind.RECORD and decl.kind != CursorKind.NO_DECL_FOUND:
            tag = decl.spelling
            if not tag or decl.is_anonymous() or tag == name:
                self.emit_record(decl, nelua_ident(name))
                return
            tagname = self.record_name(decl)
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
            tstr = self.type_str(under)
        except ValueError as e:
            self.skip(cursor, str(e))
            return
        nname = nelua_ident(name)
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
        self.emit('global function %s%s(%s)%s %s end' % (self.prefix, nelua_ident(name), ', '.join(params), rets, self.annots(cursor)))
        self.names_used.add(name)

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
            self.emit('global %s%s: %s <comptime> = %s' % (self.prefix, nelua_ident(name), ctype, value))
            self.names_used.add(name)
            return
        m = self.MACRO_FLOAT.match(body)
        if m:
            value, suffix = m.group(1), m.group(2).lower()
            ctype = 'float32' if suffix == 'f' else ('clongdouble' if suffix == 'l' else 'float64')
            self.emit('global %s%s: %s <comptime> = %s' % (self.prefix, nelua_ident(name), ctype, value))
            self.names_used.add(name)
            return
        if len(toks) == 2 and toks[1].startswith('"'):
            self.emit('global %s%s: string <comptime> = %s' % (self.prefix, nelua_ident(name), toks[1]))
            self.names_used.add(name)
            return
        if len(toks) == 2 and toks[1] in self.names_used:
            self.emit('global %s%s = %s%s' % (self.prefix, nelua_ident(name), self.prefix, nelua_ident(toks[1])))
            self.names_used.add(name)
            return
        self.skip(cursor, 'macro body is not a literal: %s' % ' '.join(toks[1:])[:60])

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
        self.emit()
        self.visit(tu.cursor)
        if not self.args.no_stubs:
            stubs = [(n, d) for n, d in self.referenced.items() if n not in self.defined and n not in self.forwarded]
            if stubs:
                self.emit()
                self.emit('-- Opaque stubs for types declared in other headers; replace with real bindings when needed.')
                for n, d in stubs:
                    kw = 'union' if d.kind == CursorKind.UNION_DECL else 'record'
                    if d.kind == CursorKind.ENUM_DECL:
                        continue
                    ctypedef = "ctypedef'%s'" % d.spelling if d.kind != CursorKind.TYPEDEF_DECL and d.spelling else ''
                    self.emit('global %s%s: type %s = @%s{}' % (self.prefix, n, self.annots(d, ctypedef, 'cincomplete'), kw))
        if self.skipped:
            self.emit()
            self.emit('-- Not generated:')
            for s in self.skipped:
                self.emit('--   ' + s)
        return '\n'.join(self.out) + '\n'


def main(argv=None):
    ap = argparse.ArgumentParser(description='Generate Nelua bindings from C headers with libclang.')
    ap.add_argument('headers', nargs='+', help='C header files to bind')
    ap.add_argument('-I', dest='include_dirs', action='append', default=[], help='include search directory')
    ap.add_argument('-D', dest='defines', action='append', default=[], help='preprocessor define')
    ap.add_argument('--target', help='clang target triple used to parse the headers')
    ap.add_argument('--include-as', help="cinclude spec written into every binding, e.g. '<zlib.h>' (default: \"basename.h\")")
    ap.add_argument('--prefix', help='emit declarations as fields of this global record (e.g. C)')
    ap.add_argument('--match', help='only bind declarations whose name matches this regex')
    ap.add_argument('--all', action='store_true', help='also bind declarations from transitively included headers')
    ap.add_argument('--include-file-regex', help='also bind declarations from included files matching this regex')
    ap.add_argument('--no-stubs', action='store_true', help='do not emit opaque stubs for types from other headers')
    ap.add_argument('--ignore-errors', action='store_true', help='generate even when clang reports errors')
    ap.add_argument('--libclang', help='path to libclang shared library')
    ap.add_argument('-o', '--output', help='output file (default: stdout)')
    ap.add_argument('clang_args', nargs='*', help='extra arguments after -- are passed to clang')
    args = ap.parse_args(argv)
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
