" File:        autoload/vorax/omni.vim
" Author:      Alexandru Tică
" Description: Provides omni completion.
" License:     see LICENSE.txt

let s:cache_items = {}

function! vorax#omni#Complete(findstart, base) abort"{{{
  if a:findstart
    let s:context = s:CompletionContext()
    call VORAXDebug("vorax#omni#Complete: context = " . string(s:context))
    return s:context['start_from']
  else
    let items = []
    if s:context['completion_type'] == 'argument'
      let items = s:ArgumentItems(a:base)
    elseif s:context['completion_type'] == 'identifier'
      let items = s:WordItems(a:base)
    elseif s:context['completion_type'] == 'dot'
      let items = s:DotItems(a:base)
    endif
    if g:vorax_omni_sort_items
      call sort(items, "s:CompareOmniItems")
    endif
    if len(items) > 0
      return items
    else
      return -2
    endif
  endif
endfunction"}}}

function! vorax#omni#SupertabPreventCompletion(text) abort"{{{
  if s:ShouldCompleteArgument(s:NonEmptyAbove())
    return 0
  endif
  if a:text =~ '\m^\s*$'
    return 1
  else
    return 0
  endif
endfunction"}}}

function! vorax#omni#ResetCache() abort"{{{
  let s:cache_items = {}
endfunction"}}}

function! s:WordItems(prefix) abort"{{{
  call VORAXDebug("omni s:WordItems a:prefix=" . string(a:prefix))
  let output = vorax#sqlplus#RunVoraxScript('omni_word.sql',
        \ toupper(a:prefix),
        \ g:vorax_omni_max_items + 1)
  call VORAXDebug('omni s:WordItems: ' . output)
  let data  = vorax#ruby#ParseResultset(output)
  let result = s:ResultsetToOmni(data, 0, s:context['text_before'], '')
  return result
endfunction"}}}

function! s:DotItems(prefix) abort"{{{
  call VORAXDebug("omni s:DotItems a:prefix=" . string(a:prefix))
  let start = match(s:context['text_before'], '\m[a-zA-Z0-9$#_.]*$') " last blank
  let end = strridx(s:context['text_before'], '.')       " last dot
  let oracle_name = strpart(s:context['text_before'], start, end - start)
  call VORAXDebug("omni s:DotItems oracle_name=" . string(oracle_name))
  if oracle_name != ''
    " before anything else, check if it's an alias
    if oracle_name !~ '\m\.' 
      let result = s:AliasItems(oracle_name, a:prefix)
      if len(result) > 0
        " it's an alias: just return its columns
        return result
      endif
    endif
    let name_metadata = vorax#sqlplus#NameResolve(oracle_name)
    if s:IsCached(name_metadata)
      let data = s:Cache(name_metadata)
    else
      if name_metadata['type'] == 'SCHEMA'
        " get all schema objects matching the prefix
        let data = s:SchemaObjects(name_metadata['schema'], a:prefix)
      elseif name_metadata['type'] == 'PACKAGE'
        if g:vorax_omni_parse_package
          let data = s:PackageItems(name_metadata['schema'], name_metadata['object'])
        else
          " get all functions/procedures from the package or type
          let data = s:PlsqlModules(name_metadata['id'])
        endif
      elseif name_metadata['type'] == 'TYPE'
        " get all functions/procedures from the package or type
        let data = s:PlsqlModules(name_metadata['id'])
      elseif name_metadata['type'] == 'TABLE' ||
            \ name_metadata['type'] == 'VIEW'
        " get all columns
        let data = s:Columns(name_metadata['schema'],
              \ name_metadata['object'])
      elseif name_metadata['type'] == 'SEQUENCE'
        let data = {'resultset' : [[ 
              \ ['nextval', 'nextval', '', ''], 
              \ ['currval', 'currval', '', ''] 
              \ ]]}
      endif
      if exists('data')
        call s:Cache(name_metadata, data)
      endif
    endif
  endif

  let result = []
  if exists('data')
    call VORAXDebug("s:DotItems data=" . string(data))
    let result = s:ResultsetToOmni(data, 0, s:context['text_before'], '')
    call filter(result, 'v:val.word =~ ''^' . a:prefix . '''')
  endif

  return result
endfunction"}}}

function! s:ArgumentItems(prefix) abort"{{{
  let result = []
  let stmt = vorax#utils#DescribeCurrentStatement(0, 0)
  call VORAXDebug("omni s:ArgumentItems(): stmt = " . string(stmt))
  " look backward in the current statement
  let module = vorax#ruby#ArgumentBelongsTo(stmt['text'], stmt['relative'])
  call VORAXDebug("omni s:ArgumentItems(): module = " . string(module))
  if module != ""
    " try to resolve this module
    let module_metadata = vorax#sqlplus#NameResolve(module)
    if module_metadata['type'] == 'FUNCTION' ||
          \ module_metadata['type'] == 'PROCEDURE' ||
          \ module_metadata['type'] == 'PACKAGE' ||
          \ module_metadata['type'] == 'TYPE'
      if s:IsCached(module_metadata)
        let data = s:Cache(module_metadata)
      else
        " successfully resolved, go on
        let output = vorax#sqlplus#RunVoraxScript('omni_arguments.sql',
              \ module_metadata['id'],
              \ module_metadata['extra'])
        let data  = vorax#ruby#ParseResultset(output)
        call s:Cache(module_metadata, data)
      endif
      call VORAXDebug("s:ArgumentItems data=" . string(data))
      let result = s:ResultsetToOmni(data, 1, module, ' ')
    endif
  endif
  return result
endfunction"}}}

function! s:AliasItems(alias, prefix) abort"{{{
  call VORAXDebug("omni s:AliasItems alias=" . string(a:alias). " prefix=" . string(a:prefix))
  let expanded_columns = []
  let stmt = vorax#utils#DescribeCurrentStatement(0, 0)
  let columns = vorax#ruby#AliasColumns(stmt.text, a:alias, stmt.relative - 1)
  call VORAXDebug("omni s:AliasItems alias columns=" . string(columns))
  for column in columns
    if column =~ '\m\*$'
      " expand baby
      let oracle_name = substitute(column, '\m\.\*$', '', 'g')
      let metadata = vorax#sqlplus#NameResolve(oracle_name)
      if metadata['type'] == 'TABLE' || metadata['type'] == 'VIEW'
        if s:IsCached(metadata)
          let data = s:Cache(metadata)
        else
          let data = s:Columns(metadata['schema'], metadata['object'])
          call s:Cache(metadata, data)
        endif
				call extend(expanded_columns, s:ResultsetToOmni(data, 0, s:context['text_before'], ''))
      endif
    else
      let rec = { 'word' : column,
                \ 'abbr' : column,
                \ 'kind' : 'column',
                \ 'menu' : '',
                \ 'icase' : 1,
                \ 'dup'  : 0 }
      call s:ConvertToOmniCase(rec, s:context['text_before'])    
      call add(expanded_columns, rec)
    endif
  endfor
  call VORAXDebug("omni s:AliasItems expanded_columns=" . string(expanded_columns))
  call filter(expanded_columns, 'v:val.word =~ ''^' . a:prefix . '''')
  return expanded_columns
endfunction"}}}

function! s:SchemaObjects(schema, prefix) abort"{{{
  let output = vorax#sqlplus#RunVoraxScript('omni_schema.sql',
        \ a:schema,
        \ toupper(a:prefix),
        \ g:vorax_omni_max_items + 1)
  return vorax#ruby#ParseResultset(output)
endfunction"}}}

function! s:PackageItems(schema, object) abort"{{{
  call VORAXDebug('omni s:PackageItems: schema=' . string(a:schema) .
        \ ' object=' . string(a:object))
  call VORAXDebug('omni s:PackageItems: fetch source...')
  let content = vorax#sqlplus#GetSource(a:schema, a:object, 'PACKAGE')
  let content = vorax#ruby#RemoveAllComments(content)
  call VORAXDebug('omni s:PackageItems: describe package...')
  let data = vorax#ruby#DescribePackageSpec(content)
  call VORAXDebug('omni s:PackageItems: data=' . string(data))
  let result = {'resultset' : [[]]} " to match the format of a resultset from the database
  for component in ['constants', 'variables', 'types', 'cursors', 'functions', 'procedures']
    for item in data[component]
      let rec = [item, item, strpart(component, 0, len(component) - 1), '']
      call s:ConvertToOmniCase(rec, s:context['text_before'])    
      call add(result.resultset[0], rec)
    endfor
  endfor
  return result
endfunction"}}}

function! s:PlsqlModules(object_id) abort"{{{
  let output = vorax#sqlplus#RunVoraxScript('omni_modules.sql', a:object_id)
  return vorax#ruby#ParseResultset(output)
endfunction"}}}

function! s:Columns(schema, object) abort"{{{
  let output = vorax#sqlplus#RunVoraxScript('omni_columns.sql',
        \ a:schema,
        \ a:object)
  return vorax#ruby#ParseResultset(output)
endfunction"}}}

function! s:CompletionContext() abort"{{{
  let context = { 'start_from' : -1,
                \ 'current_line' : strpart(getline('.'), 0, col('.') - 1),
                \ 'current_col' : col('.'),
                \ 'text_before' : s:NonEmptyAbove(),
                \ 'completion_type' : ''}

  " guess completion type on the current position
  if s:ShouldCompleteArgument(context['text_before'])
    let context['completion_type'] = 'argument'
    let context['start_from'] = col('.') - 1
  else
    let context['start_from'] = s:DotMatch(context['current_line'])
    if context['start_from'] != -1
      let context.completion_type = 'dot'
    else
      let context['start_from'] = s:IdentifierMatch(context['current_line'])
      if context['start_from'] != -1
        let context.completion_type = 'identifier'
      endif
    endif
  endif
  return context
endfunction"}}}

function! s:ResultsetToOmni(data, allow_dup, case_probe, padd_with) abort"{{{
  let result = []
  let data = a:data
  if exists('data["resultset"][0]')
    let rs = data["resultset"][0]
    if len(rs) > g:vorax_omni_max_items
      " too many items, give up
      call VORAXDebug("omni s:ResultsetToOmni => Too many items")
      call vorax#utils#SpitWarn('Too many completion items...')
      " wait, otherwise the user can't see the above message
      if g:vorax_omni_too_many_items_warn_delay > 0
        exe 'sleep ' . g:vorax_omni_too_many_items_warn_delay . 'm'
      endif
    else
      for rec in rs
        call s:ConvertToOmniCase(rec, a:case_probe)    
        " the extra ws for word is needed because sqlplus doesn't
        " preserve the trailing ws
        if rec[2] == 'constant' && g:vorax_omni_force_upcase_const
          let rec[0] = toupper(rec[0])
          let rec[1] = toupper(rec[1])
        endif
        call add(result, {
              \ 'word' : rec[0] . a:padd_with,
              \ 'abbr' : rec[1],
              \ 'kind' : rec[2],
              \ 'menu' : rec[3],
              \ 'icase': 1,
              \ 'dup'  : str2nr(a:allow_dup)})
      endfor
    endif
  endif
  return result
endfunction"}}}

function! s:ShouldCompleteArgument(text) abort"{{{
  return a:text =~ '\m[(,]\s*$'
endfunction"}}}

function! s:DotMatch(text) abort"{{{
  return match(a:text, '\m\([.]\)\@<=\w*$')
endfunction"}}}

function! s:IdentifierMatch(text) abort"{{{
  return match(a:text, '\m[A-Za-z0-9#$_]\{' . g:vorax_omni_word_prefix_size . ',\}$')
endfunction"}}}

function! s:NonEmptyAbove() abort"{{{
  let line_no = line('.')
  let col_no = col('.')
  let first = 1
  if line_no > 0
    while 1
      let text = getline(line_no)
      if line_no <= 0 || text =~ '\S'
        break
      endif
      let first = 0
      let line_no -= 1
    endwhile
    if first
      return strpart(text, 0, col_no - 1)
    else
      return text
    endif
  else
    return ''
  endif
endfunction"}}}

function! s:DetectCase(...) abort"{{{
  if exists('a:1')
    let base = a:1
  else
    let base = s:context['text_before']
  endif
  let last_letter = matchstr(substitute(base, '\V\A\$', '', 'g'), '\V\a\$')
  if last_letter ==# tolower(last_letter)
    return 'lower'
  elseif last_letter ==# toupper(last_letter)
    return 'upper'
  endif
endfunction"}}}

function! s:OmniCase(...) abort"{{{
  let omni_case = g:vorax_omni_case
  if omni_case ==? 'smart' ||
        \ omni_case ==? 'upper' ||
        \ omni_case ==? 'lower'
    let omni_case = tolower(omni_case)
  endif
  if omni_case == 'smart'
    if exists('a:1')
      let base = a:1
      let omni_case = s:DetectCase(base)
    else
      let omni_case = s:DetectCase()
    endif
  endif
  return omni_case
endfunction"}}}

function! s:ConvertToOmniCase(array, ...)"{{{
  if exists('a:1')
    let case = s:OmniCase(a:1)
  else
    let case = s:OmniCase()
  endif
  if case == 'lower'
    return map(a:array, 'tolower(v:val)')
  elseif case == 'upper'
    return map(a:array, 'toupper(v:val)')
  endif
endfunction"}}}

function! s:CompareOmniItems(i1, i2)"{{{
  let i1 = toupper(a:i1.word)
  let i2 = toupper(a:i2.word)
  return i1 == i2 ? 0 : i1 > i2 ? 1 : -1
endfunction"}}}

function! s:IsCached(metadata) abort"{{{
  let key = a:metadata['id'] . ':' . a:metadata['extra']
  return has_key(s:cache_items, key)
endfunction"}}}

function! s:Cache(metadata, ...) abort"{{{
  if a:metadata.id != ''
    let key = a:metadata.id . ':' . a:metadata.extra
    if exists('a:1')
      let data = a:1
      for cache_schema in g:vorax_omni_cache
        if cache_schema ==? a:metadata['schema']
          if len(data) > 0
            let s:cache_items[key] = data
          endif
          break
        endif
      endfor
    else
      if s:IsCached(a:metadata)
        return s:cache_items[key]
      endif
    endif
  endif
endfunction"}}}

