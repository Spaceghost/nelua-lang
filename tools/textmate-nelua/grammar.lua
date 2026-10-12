-- TextMate's required external grammar schema; no Lua fallback language scope.
return {
  name='Nelua', scopeName='source.nelua', fileTypes={'nelua'},
  patterns={
    {include='#comments'}, {include='#preprocessor'}, {include='#strings'},
    {include='#annotations'}, {include='#functions'}, {include='#numbers'},
    {include='#types'}, {include='#keywords'}, {include='#operators'},
  },
  repository={
    comments={patterns={
      {name='comment.block.nelua',begin='(--)(\\[)(=*)(\\[)',
        ['end']='\\]\\3\\]',beginCaptures={['1']={name='punctuation.definition.comment.nelua'}}},
      {name='comment.line.double-dash.nelua',match='--[^\\r\\n]*'},
    }},
    preprocessor={patterns={
      {name='meta.preprocessor.block.nelua',contentName='source.lua.embedded.nelua',
        begin='##(\\[)(=*)(\\[)',['end']='\\]\\2\\]',patterns={{include='#strings'},{include='source.lua'}}},
      {name='meta.preprocessor.inline.nelua',begin='#\\[',['end']='\\]#',patterns={{include='#strings'},{include='source.lua'}}},
      {name='meta.preprocessor.name.nelua',begin='#\\|',['end']='\\|#',patterns={{include='#strings'},{include='source.lua'}}},
      {name='meta.preprocessor.line.nelua',begin='##',['end']='$',patterns={{include='#strings'},{include='source.lua'}}},
    }},
    strings={patterns={
      {name='string.quoted.other.long.nelua',begin='\\[(=*)\\[',['end']='\\]\\1\\]'},
      {name='string.quoted.double.nelua',begin='"',['end']='"[A-Za-z_0-9]*',patterns={{name='constant.character.escape.nelua',match='\\\\(?:u\\{[0-9a-fA-F]+\\}|x[0-9a-fA-F]{2}|[0-9]{1,3}|.)'}}},
      {name='string.quoted.single.nelua',begin="'",['end']="'[A-Za-z_0-9]*",patterns={{name='constant.character.escape.nelua',match='\\\\(?:u\\{[0-9a-fA-F]+\\}|x[0-9a-fA-F]{2}|[0-9]{1,3}|.)'}}},
    }},
    annotations={patterns={
      {name='meta.annotation.nelua',
        begin='(?<=[A-Za-z_0-9\\)])\\s*(<)(?=\\s*(?:cimport|cexport|comptime|const|nodecl|ctypedef|codename|inline|noinline|cincomplete|volatile|packed|align|deprecated|polymorphic)\\b)',
        ['end']='>',patterns={{include='#strings'},{include='#numbers'},
          {name='entity.other.attribute-name.nelua',match='\\b[A-Za-z_][A-Za-z_0-9]*\\b'}},
      },
    }},
    functions={patterns={
      {match='\\b(?:(local|global)\\s+)?(function)\\s+([\\p{L}_][\\p{L}\\p{N}_]*(?:[.:][\\p{L}_][\\p{L}\\p{N}_]*)*)',
        captures={['1']={name='storage.modifier.nelua'},['2']={name='storage.type.function.nelua'},['3']={name='entity.name.function.nelua'}}},
    }},
    numbers={patterns={
      {name='constant.numeric.nelua',match='(?<![A-Za-z_0-9])(?:0[xX][0-9a-fA-F]+(?:\\.[0-9a-fA-F]*)?(?:[pP][+-]?[0-9]+)?|0[bB][01]+(?:\\.[01]*)?(?:[pP][+-]?[0-9]+)?|(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?)(?:_[A-Za-z_0-9]+)?'},
    }},
    types={patterns={
      {match='(@)\\s*(record|union|enum|array|pointer|variant)\\b',captures={['1']={name='keyword.operator.nelua'},['2']={name='storage.type.nelua'}}},
      {name='storage.type.nelua',match='\\b(?:boolean|cchar|cint|csize|cstring|float(?:32|64|128)?|int(?:8|16|32|64|128)?|uint(?:8|16|32|64|128)?|isize|usize|number|string|table|type|void)\\b'},
    }},
    keywords={patterns={
      {name='storage.modifier.nelua',match='\\b(?:local|global)\\b'},
      {name='constant.language.nelua',match='\\b(?:true|false|nil|nilptr)\\b'},
      {name='keyword.control.nelua',match='\\b(?:function|end|if|then|elseif|else|switch|case|for|in|do|while|repeat|until|defer|return|break|continue|fallthrough|goto)\\b'},
      {name='keyword.operator.nelua',match='\\b(?:and|or|not)\\b'},
    }},
    operators={patterns={{name='keyword.operator.nelua',match='>>>|<<|>>|///|//|%%%|~=|==|<=|>=|\\.\\.|[+*/%&|~^#$@<>=-]'}}},
  },
}
