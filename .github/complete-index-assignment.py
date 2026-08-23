#!/usr/bin/env python3

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str, description: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one {description}, found {count}")
    path.write_text(text.replace(old, new, 1))


def add_tests() -> None:
    path = Path("spec/analyzer_spec.lua")
    anchor = '''  expect.analyze_error([[
    local R = @record{}
    function R:__index(x: integer): integer return 0 end
    local r: R
    r[0] = 1
  ]], "cannot assign to rvalue")
'''
    replacement = anchor + '''  expect.analyze_error([[
    local Cell = @record{x: integer}
    local R = @record{}
    function R:__index(x: integer): Cell return Cell{} end
    local r: R
    r[0].x = 1
  ]], "cannot assign to rvalue")
  expect.analyze_error([[
    local Cell = @record{items: [1]integer}
    local R = @record{}
    function R:__index(x: integer): Cell return Cell{} end
    local r: R
    r[0].items[0] = 1
  ]], "cannot assign to rvalue")
  expect.analyze_ast([[
    local Cell = @record{x: integer}
    local R = @record{cell: Cell}
    function R:__index(x: integer): *Cell return &self.cell end
    local r: R
    r[0].x = 1
  ]])
'''
    replace_once(path, anchor, replacement, "direct __index assignment regression")


def add_fix() -> None:
    path = Path("lualib/nelua/analyzer.lua")

    old = '''local function visitor_FieldIndex(context, node)
  local name, objnode = node[1], node[2]
  context:traverse_node(objnode)
  local objattr = objnode.attr
  local objtype = objattr.type
  local attr = node.attr
'''
    new = '''local function visitor_FieldIndex(context, node)
  local name, objnode = node[1], node[2]
  context:traverse_node(objnode)
  local objattr = objnode.attr
  local objtype = objattr.type
  local objispointer = objtype and objtype.is_pointer
  local attr = node.attr
'''
    replace_once(path, old, new, "field index object setup")

    old = '''  if objattr.const then
    attr.const = true
  end
  return ret
end

visitors.DotIndex = visitor_FieldIndex
'''
    new = '''  if objattr.const then
    attr.const = true
  end
  if objattr.readonlyindex and not objispointer then
    attr.readonlyindex = true
  end
  return ret
end

visitors.DotIndex = visitor_FieldIndex
'''
    replace_once(path, old, new, "field index attribute propagation")

    old = '''function visitors.KeyIndex(context, node)
  local indexnode, objnode = node[1], node[2]
  context:traverse_node(indexnode)
  context:traverse_node(objnode)
  local attr = node.attr
  if attr.type then
    if indexnode.done and objnode.done then node.done = true end
    return
  end
  if node.checked then return end
  local objattr = objnode.attr
  local objtype = objattr.type
  if objtype then
'''
    new = '''function visitors.KeyIndex(context, node)
  local indexnode, objnode = node[1], node[2]
  context:traverse_node(indexnode)
  context:traverse_node(objnode)
  local attr = node.attr
  if attr.type then
    if indexnode.done and objnode.done then node.done = true end
    return
  end
  if node.checked then return end
  local objattr = objnode.attr
  local objtype = objattr.type
  local objispointer = objtype and objtype.is_pointer
  if objtype then
'''
    replace_once(path, old, new, "key index object setup")

    old = '''  if objattr.const then
    attr.const = true
  end
  if attr.type then
    node.checked = true
'''
    new = '''  if objattr.const then
    attr.const = true
  end
  if objattr.readonlyindex and not objispointer then
    attr.readonlyindex = true
  end
  if attr.type then
    node.checked = true
'''
    replace_once(path, old, new, "key index attribute propagation")


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"test", "fix", "all"}:
        raise SystemExit("usage: complete-index-assignment.py test|fix|all")
    mode = sys.argv[1]
    if mode in {"test", "all"}:
        add_tests()
    if mode in {"fix", "all"}:
        add_fix()


if __name__ == "__main__":
    main()
