" Location: autoload/fireplace.vim
" Author: Tim Pope <http://tpo.pe/>

if exists('g:autoloaded_fireplace')
  finish
endif
let g:autoloaded_fireplace = 1

" Section: Utilities

function! s:map(mode, lhs, rhs, ...) abort
  if get(g:, 'fireplace_no_maps')
    return
  endif
  let flags = (a:0 ? a:1 : '') . (a:rhs =~# '^<Plug>' ? '' : '<script>')
  let head = a:lhs
  let tail = ''
  let keys = get(g:, a:mode.'remap', {})
  if type(keys) != type({})
    return
  endif
  while !empty(head)
    if has_key(keys, head)
      let head = keys[head]
      if empty(head)
        return
      endif
      break
    endif
    let tail = matchstr(head, '<[^<>]*>$\|.$') . tail
    let head = substitute(head, '<[^<>]*>$\|.$', '', '')
  endwhile
  if flags !~# '<unique>' || empty(mapcheck(head.tail, a:mode))
    exe a:mode.'map <buffer>' flags head.tail a:rhs
  endif
endfunction

function! s:pr(obj) abort
  if type(a:obj) == v:t_string
    return a:obj
  elseif type(a:obj) == v:t_list
    return '(' . join(map(copy(a:obj), 's:pr(v:val)'), ' ') . ')'
  elseif type(a:obj) == v:t_dict
    return '{' . join(map(keys(a:obj), 's:pr(v:val) . " " . s:pr(a:obj[v:val])'), ', ') . '}'
  else
    return string(a:obj)
  endif
endfunction

function! s:cword() abort
  let isk = &l:iskeyword
  try
    setlocal iskeyword+='
    return substitute(expand('<cword>'), "^''*", '', '')
  finally
    let &l:iskeyword = isk
  endtry
endfunction

" Section: Escaping

function! s:str(string) abort
  return '"' . escape(a:string, '"\') . '"'
endfunction

function! s:qsym(symbol) abort
  if a:symbol =~# '^[[:alnum:]?*!+/=<>.:-]\+$'
    return "'".a:symbol
  else
    return '(symbol '.s:str(a:symbol).')'
  endif
endfunction

function! s:to_ns(path) abort
  return tr(substitute(a:path, '\.\w\+$', '', ''), '\/_', '..-')
endfunction

" Section: Completion

let s:jar_contents = {}

function! fireplace#jar_contents(path) abort
  if !exists('s:pythonx')
    let s:pythonx = 0
    if has('pythonx')
      try
        pythonx import zipfile
        let s:pythonx = 1
      catch /^Vim(pythonx):Traceback/
      endtry
    endif
  endif

  if !exists('s:zipinfo')
    if executable('zipinfo')
      let s:zipinfo = 'zipinfo -1 '
    elseif executable('jar')
      let s:zipinfo = 'jar tf '
    elseif executable('python')
      let s:zipinfo = 'python -c '.shellescape('import zipfile, sys; print chr(10).join(zipfile.ZipFile(sys.argv[1]).namelist())').' '
    elseif executable('python3')
      let s:zipinfo = 'python3 -c '.shellescape('import zipfile, sys; print chr(10).join(zipfile.ZipFile(sys.argv[1]).namelist())').' '
    else
      let s:zipinfo = ''
    endif
  endif

  if !has_key(s:jar_contents, a:path)
    if !filereadable(a:path)
      let s:jar_contents[a:path] = []
    elseif s:pythonx
      try
        let s:jar_contents[a:path] = pyxeval('zipfile.ZipFile(' . json_encode(a:path) . ').namelist()')
      catch /^Vim(let):Traceback/
        let s:jar_contents[a:path] = []
      endtry
    elseif !empty(s:zipinfo)
      let s:jar_contents[a:path] = split(system(s:zipinfo . shellescape(a:path)), "\n")
      if v:shell_error
        let s:jar_contents[a:path] = []
      endif
    endif
  endif

  return copy(get(s:jar_contents, a:path, []))
endfunction

function! fireplace#eval_complete(A, L, P) abort
  let prefix = matchstr(a:A, '\%(.* \|^\)\%(#\=[\[{('']\)*')
  let keyword = a:A[strlen(prefix) : -1]
  return sort(map(fireplace#omnicomplete(0, keyword, 1), 'prefix . v:val.word'))
endfunction

function! fireplace#ns_complete(A, L, P) abort
  let matches = []
  for dir in fireplace#path()
    if dir =~# '\.jar$'
      let files = filter(fireplace#jar_contents(dir), 'v:val =~# "\\.clj$"')
    else
      let files = split(glob(dir."/**/*.clj", 1), "\n")
      call map(files, 'v:val[strlen(dir)+1 : -1]')
    endif
    let matches += files
  endfor
  return filter(map(matches, 's:to_ns(v:val)'), 'a:A ==# "" || a:A ==# v:val[0 : strlen(a:A)-1]')
endfunction

let s:short_types = {
      \ 'function': 'f',
      \ 'macro': 'm',
      \ 'var': 'v',
      \ 'special-form': 's',
      \ 'class': 'c',
      \ 'keyword': 'k',
      \ 'local': 'l',
      \ 'namespace': 'n',
      \ 'field': 'i',
      \ 'method': 'f',
      \ 'static-field': 'i',
      \ 'static-method': 'f',
      \ 'resource': 'r'
      \ }

function! s:candidate(val) abort
  let type = get(a:val, 'type', '')
  let arglists = get(a:val, 'arglists', [])
  return {
        \ 'word': get(a:val, 'candidate'),
        \ 'kind': get(s:short_types, type, type),
        \ 'info': get(a:val, 'doc', ''),
        \ 'menu': empty(arglists) ? '' : '(' . join(arglists, ' ') . ')'
        \ }
endfunction

function! s:get_complete_context() abort
  " Find toplevel form
  " If cursor is on start parenthesis we don't want to find the form
  " If cursor is on end parenthesis we want to find the form
  let [line1, col1] = searchpairpos('(', '', ')', 'Wrnb', g:fireplace#skip)
  let [line2, col2] = searchpairpos('(', '', ')', 'Wrnc', g:fireplace#skip)

  if (line1 == 0 && col1 == 0) || (line2 == 0 && col2 == 0)
    return ""
  endif

  if line1 == line2
    let expr = getline(line1)[col1-1 : col2-1]
  else
    let expr = getline(line1)[col1-1 : -1] . ' '
          \ . join(getline(line1+1, line2-1), ' ')
          \ . getline(line2)[0 : col2-1]
  endif

  " Calculate the position of cursor inside the expr
  if line1 == line('.')
    let p = col('.') - col1
  else
    let p = strlen(getline(line1)[col1-1 : -1])
          \ + strlen(join(getline(line1 + 1, line('.') - 1), ' '))
          \ + col('.')
  endif

  return strpart(expr, 0, p) . ' __prefix__ ' . strpart(expr, p)
endfunction

function! s:complete_extract(msg) abort
  let trans = '{"word": (v:val =~# ''[./]'' ? "" : matchstr(a:base, ''^.\+/'')) . v:val}'
  let value = get(a:msg, 'value', get(a:msg, 'completions'))
  if type(value) == type([])
    if type(get(value, 0)) == type({})
      return map(value, 's:candidate(v:val)')
    elseif type(get(value, 0)) == type([])
      return map(value[0], trans)
    elseif type(get(value, 0)) == type('')
      return map(value, trans)
    else
      return []
    endif
  endif
endfunction

function! s:complete_add(msg) abort
  for entry in s:complete_extract(a:msg)
    call complete_add(entry)
  endfor
endfunction

function! fireplace#omnicomplete(findstart, base, ...) abort
  if a:findstart
    let line = getline('.')[0 : col('.')-2]
    return col('.') - strlen(matchstr(line, '\k\+$')) - 1
  else
    try

      if fireplace#op_available('complete')
        let request = {
              \ 'op': 'complete',
              \ 'symbol': a:base,
              \ 'extra-metadata': ['arglists', 'doc'],
              \ 'context': a:0 ? '' : s:get_complete_context()
              \ }
        if a:0
          return s:complete_extract(fireplace#message(request, v:t_dict))
        endif
        let id = fireplace#message(request, function('s:complete_add')).id
        while !fireplace#client().done(id)
          call complete_check()
          sleep 1m
        endwhile
        return []
      endif

      let omnifier = '(fn [[k v]] (let [{:keys [arglists] :as m} (meta v)]' .
            \ ' {:word k :menu (pr-str (or arglists (symbol ""))) :info (str (when arglists (str arglists "\n")) "  " (:doc m)) :kind (if arglists "f" "v")}))'

      let ns = fireplace#ns()

      let [aliases, namespaces, maps] = fireplace#evalparse(
            \ '[(ns-aliases '.s:qsym(ns).') (all-ns) '.
            \ '(sort-by :word (map '.omnifier.' (ns-map '.s:qsym(ns).')))]')

      if a:base =~# '^[^/]*/[^/]*$'
        let ns = matchstr(a:base, '^.*\ze/')
        let prefix = ns . '/'
        let ns = get(aliases, ns, ns)
        let keyword = matchstr(a:base, '.*/\zs.*')
        let results = fireplace#evalparse(
              \ '(sort-by :word (map '.omnifier.' (ns-publics '.s:qsym(ns).')))')
        for r in results
          let r.word = prefix . r.word
        endfor
      else
        let keyword = a:base
        let results = maps + map(sort(keys(aliases) + namespaces), '{"word": v:val."/", "kind": "t", "info": ""}')
      endif
      if type(results) == type([])
        return filter(results, 'a:base ==# "" || a:base ==# v:val.word[0 : strlen(a:base)-1]')
      else
        return []
      endif
    catch /.*/
      return []
    endtry
  endif
endfunction

" Section: REPL client

let s:repl = {"requires": {}}

if !exists('s:repls')
  let s:repls = []
  let s:repl_paths = {}
  let s:repl_portfiles = {}
endif

function! s:repl.path() dict abort
  return self.transport._path
endfunction

function! s:conn_try(connection, function, ...) abort
  try
    return call(a:connection[a:function], a:000, a:connection)
  catch /^\w\+ Connection Error:/
    call s:unregister(a:connection)
    throw v:exception
  endtry
endfunction

function! s:repl.message(payload, ...) dict abort
  if has_key(a:payload, 'ns') && a:payload.ns !=# self.user_ns()
    let ignored_error = self.preload(a:payload.ns)
  endif
  return call('s:conn_try', [get(self, 'session', get(self, 'connection', {})), 'message', a:payload] + a:000, self)
endfunction

function! s:repl.done(id) dict abort
  if type(a:id) == v:t_string
    return !has_key(self.transport.requests, a:id)
  elseif type(a:id) == v:t_dict
    return index(get(a:id, 'status', []), 'done') >= 0
  else
    return -1
  endif
endfunction

function! s:repl.preload(lib) dict abort
  if !empty(a:lib) && a:lib !=# self.user_ns() && !get(self.requires, a:lib)
    let reload = has_key(self.requires, a:lib) ? ' :reload' : ''
    let self.requires[a:lib] = 0
    let clone = s:conn_try(get(self, 'session', get(self, 'connection', {})), 'clone')
    if self.user_ns() ==# 'user'
      let qsym = s:qsym(a:lib)
      let expr = '(when-not (find-ns '.qsym.') (try'
            \ . ' (#''clojure.core/load-one '.qsym.' true true)'
            \ . ' (catch Exception e (when-not (find-ns '.qsym.') (throw e)))))'
    else
      let expr = '(ns '.self.user_ns().' (:require '.a:lib.reload.'))'
    endif
    let result = self.session.message({'op': 'eval', 'code': expr, 'ns': self.user_ns(), 'session': ''}, v:t_dict)
    let self.requires[a:lib] = !has_key(result, 'ex')
    if has_key(result, 'ex')
      return result
    endif
  endif
  return {}
endfunction

let s:piggieback = copy(s:repl)

function! s:repl.piggieback(arg, ...) abort
  if a:0 && a:1
    if len(self.piggiebacks)
      let piggieback = remove(self.piggiebacks, 0)
      call piggieback.message({'op': 'eval', 'code': ':cljs/quit'}, v:t_list)
      call piggieback.session.close()
    endif
    return {}
  endif

  let session = s:conn_try(get(self, 'session', get(self, 'connection', {})), 'clone')
  if empty(a:arg) && exists('b:fireplace_cljs_repl')
    let arg = b:fireplace_cljs_repl
  elseif empty(a:arg)
    let arg = ''
    if exists('*projectionist#query_scalar')
      let arg = get(projectionist#query_scalar('fireplaceCljsRepl') + projectionist#query_scalar('cljsRepl'), 0, '')
    endif
    if empty(arg)
      let arg = get(g:, 'fireplace_cljs_repl', '')
    endif
  elseif a:arg =~# '^\d\{1,5}$'
    if len(fireplace#findresource('weasel/repl/websocket.clj', self.path()))
      let arg = '(weasel.repl.websocket/repl-env :port ' . a:arg . ')'
    else
      let arg = '(cljs.repl.browser/repl-env :port ' . a:arg .')'
    endif
  else
    let arg = a:arg
  endif
  if empty(arg)
    throw 'Fireplace: no default ClojureScript REPL'
  endif
  let replns = matchstr(arg, '^\%((\w\+\.piggieback/cljs-repl \)\=(\=\zs[a-z][a-z0-9-]\+\.[a-z0-9.-]\+\ze/')
  if len(replns)
    call session.message({'op': 'eval', 'code': "(require '" . replns . ")"}, v:t_dict)
  endif
  if arg =~# '^\S*repl-env\>' || arg !~# '('
    if len(fireplace#findresource('cemerick/piggieback.clj', self.path())) && !len(fireplace#findresource('cider/piggieback.clj', self.path()))
      let arg = '(cemerick.piggieback/cljs-repl ' . arg . ')'
    else
      let arg = '(cider.piggieback/cljs-repl ' . arg . ')'
    endif
  endif
  let response = session.message({'op': 'eval', 'code': arg}, v:t_dict)

  if empty(get(response, 'ex'))
    call insert(self.piggiebacks, extend({'session': session, 'transport': session.transport}, deepcopy(s:piggieback)))
    return {}
  endif
  call session.close()
  return response
endfunction

function! s:piggieback.user_ns() abort
  return 'cljs.user'
endfunction

function! s:piggieback.eval(expr, options) abort
  let result = call(s:repl.eval, [a:expr, a:options], self)
  if a:expr =~# '^\s*:cljs/quit\s*$'
    let session = remove(self, 'session')
    call session.close()
  endif
  return result
endfunction

function! s:repl.user_ns() abort
  return 'user'
endfunction

function! s:repl.eval(expr, options) dict abort
  if has_key(a:options, 'ns') && a:options.ns !=# self.user_ns()
    let error = self.preload(a:options.ns)
    if !empty(error)
      return error
    endif
  endif
  let response = self.message(extend({'op': 'eval', 'code': a:expr}, a:options), v:t_dict)
  if index(response.status, 'namespace-not-found') < 0
    return response
  endif
  throw 'Fireplace: namespace not found: ' . get(a:options, 'ns', 'user')
endfunction

function! s:register(session, ...) abort
  call insert(s:repls, extend({'session': a:session, 'transport': a:session.transport, 'piggiebacks': []}, deepcopy(s:repl)))
  if a:0 && a:1 !=# ''
    let s:repl_paths[a:1] = s:repls[0]
  endif
  return s:repls[0]
endfunction

function! s:unregister(transport) abort
  let transport = get(a:transport, 'transport', a:transport)
  call filter(s:repl_paths, 'get(v:val, "connection", v:val).transport isnot# transport')
  call filter(s:repls, 'get(v:val, "connection", v:val).transport isnot# transport')
  call filter(s:repl_portfiles, 'get(v:val, "connection", v:val).transport isnot# transport')
endfunction

function! fireplace#register_port_file(portfile, ...) abort
  let portfile = fnamemodify(a:portfile, ':p')
  let old = get(s:repl_portfiles, portfile, {})
  if has_key(old, 'time') && getftime(portfile) !=# old.time
    call s:unregister(get(old, 'transport', get(old, 'connection', {})))
    let old = {}
  endif
  if empty(old) && getfsize(portfile) > 0
    let port = matchstr(readfile(portfile, 'b', 1)[0], '\d\+')
    try
      let transport = fireplace#transport#connect(port)
      let session = transport.clone()
      let s:repl_portfiles[portfile] = {
            \ 'time': getftime(portfile),
            \ 'session': session,
            \ 'transport': transport}
      call s:register(session, a:0 ? a:1 : '')
      return session
    catch /^Fireplace:/
      if &verbose
        echohl WarningMSG
        echomsg v:exception
        echohl None
      endif
      return {}
    endtry
  else
    return get(old, 'transport', {})
  endif
endfunction

" Section: :Connect

function! fireplace#connect_complete(A, L, P) abort
  let proto = matchstr(a:A, '\w\+\ze://')
  if proto ==# ''
    let options = map(['nrepl'], 'v:val."://"')
  else
    let rest = matchstr(a:A, '://\zs.*')
    let options = ['localhost:']
    call map(options, 'proto."://".v:val')
  endif
  if a:A !=# ''
    call filter(options, 'v:val[0 : strlen(a:A)-1] ==# a:A')
  endif
  return options
endfunction

function! fireplace#connect_command(line1, line2, range, count, bang, mods, reg, arg, args) abort
  let str = substitute(get(a:args, 0, ''), '^file:[\/]\{' . (has('win32') ? '3' : '2') . '\}', '', '')
  if str !~# ':\d\|:[\/][\/]' && filereadable(str)
    let path = fnamemodify(str, ':p:h')
    let str = readfile(str, '', 1)[0]
  elseif str !~# ':\d\|:[\/][\/]' && filereadable(str . '/.nrepl-port')
    let path = fnamemodify(str, ':p:h')
    let str = readfile(str . '/.nrepl-port', '', 1)[0]
  else
    let path = fnamemodify(exists('b:java_root') ? b:java_root : fnamemodify(expand('%'), ':p:s?.*\zs[\/]src[\/].*??'), ':~')
  endif
  try
    let transport = fireplace#transport#connect(str)
  catch /.*/
    return 'echoerr '.string(v:exception)
  endtry
  if type(transport) !=# type({}) || empty(transport)
    return ''
  endif
  let client = s:register(transport.clone())
  echo 'Connected to ' . transport.url
  let root = len(a:args) > 1 ? expand(a:args[1]) : input('Scope connection to: ', path, 'dir')
  if root !=# '' && root !=# '-'
    let s:repl_paths[fnamemodify(root, ':p:s?.\zs[\/]$??')] = client
  endif
  return ''
endfunction

function! s:piggieback(count, arg, remove) abort
  try
    let response = fireplace#platform().piggieback(a:arg, a:remove)
    call s:output_response(response)
    return ''
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

function! s:set_up_connect() abort
  command! -buffer -bang -bar -complete=customlist,fireplace#connect_complete -nargs=*
        \ Connect FireplaceConnect<bang> <args>
  command! -buffer -bang -range=-1 -complete=customlist,fireplace#eval_complete -nargs=*
        \ Piggieback exe s:piggieback(<count>, <q-args>, <bang>0)
endfunction

" Section: Java runner

let s:oneoff_pr  = tempname()
let s:oneoff_ex  = tempname()
let s:oneoff_in  = tempname()
let s:oneoff_out = tempname()
let s:oneoff_err = tempname()

function! s:spawning_eval(classpath, expr, ns) abort
  if a:ns !=# '' && a:ns !=# 'user'
    let ns = '(require '.s:qsym(a:ns).') (in-ns '.s:qsym(a:ns).') '
  else
    let ns = ''
  endif
  call writefile([], s:oneoff_pr, 'b')
  call writefile([], s:oneoff_ex, 'b')
  call writefile(split('(do '.a:expr.')', "\n"), s:oneoff_in, 'b')
  call writefile([], s:oneoff_out, 'b')
  call writefile([], s:oneoff_err, 'b')
  let java_cmd = exists('$JAVA_CMD') ? $JAVA_CMD : 'java'
  let command = java_cmd.' -cp '.shellescape(a:classpath).' clojure.main -e ' .
        \ shellescape(
        \   '(binding [*out* (java.io.FileWriter. '.s:str(s:oneoff_out).')' .
        \   '          *err* (java.io.FileWriter. '.s:str(s:oneoff_err).')]' .
        \   '  (try' .
        \   '    (require ''clojure.repl ''clojure.java.javadoc) '.ns.'(spit '.s:str(s:oneoff_pr).' (pr-str (eval (read-string (slurp '.s:str(s:oneoff_in).')))))' .
        \   '    (catch Exception e' .
        \   '      (spit *err* (.toString e))' .
        \   '      (spit '.s:str(s:oneoff_ex).' (class e))))' .
        \   '  nil)')
  let captured = system(command)
  let result = {}
  let result.value = [join(readfile(s:oneoff_pr, 'b'), "\n")]
  let result.out   = join(readfile(s:oneoff_out, 'b'), "\n")
  let result.err   = join(readfile(s:oneoff_err, 'b'), "\n")
  let result.ex    = join(readfile(s:oneoff_ex, 'b'), "\n")
  if empty(result.ex)
    let result.status = ['done']
  else
    let result.status = ['eval-error', 'done']
  endif
  call filter(result, '!empty(v:val)')
  if v:shell_error && get(result, 'ex', '') ==# ''
    throw 'Error running Java: '.get(split(captured, "\n"), -1, '')
  else
    return result
  endif
endfunction

let s:no_repl = 'Fireplace: no live REPL connection'

let s:oneoff = {}

function! s:oneoff.user_ns() abort
  return 'user'
endfunction

function! s:oneoff.path() dict abort
  return self._path
endfunction

function! s:oneoff.eval(expr, options) dict abort
  if !empty(get(a:options, 'session', 1))
    throw s:no_repl
  endif
  let result = s:spawning_eval(join(self.path(), has('win32') ? ';' : ':'),
        \ a:expr, get(a:options, 'ns', self.user_ns()))
  if has_key(a:options, 'id')
    let result.id = a:options.id
  endif
  return result
endfunction

function! s:oneoff.message(...) abort
  throw s:no_repl
endfunction

let s:oneoff.piggieback = s:oneoff.message

" Section: Client

function! s:buffer_path(...) abort
  let buffer = a:0 ? a:1 : s:buf()
  if getbufvar(buffer, '&buftype') =~# '^no'
    return ''
  endif
  let path = substitute(fnamemodify(bufname(buffer), ':p'), '\C^zipfile:\(.*\)::', '\1/', '')
  for dir in fireplace#path(buffer)
    if dir !=# '' && path[0 : strlen(dir)-1] ==# dir && path[strlen(dir)] =~# '[\/]'
      return path[strlen(dir)+1:-1]
    endif
  endfor
  return ''
endfunction

function! fireplace#ns(...) abort
  let buffer = a:0 ? a:1 : s:buf()
  if !empty(getbufvar(buffer, 'fireplace_ns'))
    return getbufvar(buffer, 'fireplace_ns')
  endif
  let head = getbufline(buffer, 1, 500)
  let blank = '^\s*\%(;.*\)\=$'
  call filter(head, 'v:val !~# blank')
  let keyword_group = '[A-Za-z0-9_?*!+/=<>.-]'
  let lines = join(head[0:49], ' ')
  let lines = substitute(lines, '"\%(\\.\|[^"]\)*"\|\\.', '', 'g')
  let lines = substitute(lines, '\^\={[^{}]*}', '', '')
  let lines = substitute(lines, '\^:'.keyword_group.'\+', '', 'g')
  let ns = matchstr(lines, '\C^(\s*\%(in-ns\s*''\|ns\s\+\)\zs'.keyword_group.'\+\ze')
  if ns !=# ''
    return ns
  endif
  let path = s:buffer_path(buffer)
  return s:to_ns(path ==# '' ? s:user_ns(buffer) : path)
endfunction

function! s:buf() abort
  if exists('s:input')
    return s:input
  elseif has_key(s:qffiles, expand('%:p'))
    return s:qffiles[expand('%:p')].buffer
  else
    return '%'
  endif
endfunction

function! s:impl_ns(...) abort
  let buf = a:0 ? a:1 : s:buf()
  if fnamemodify(bufname(buf), ':e') ==# 'cljs'
    return 'cljs'
  endif
  return 'clojure'
endfunction

function! s:repl_ns(...) abort
  return s:impl_ns(a:0 ? a:1 : s:buf()) . '.repl'
endfunction

function! s:user_ns(...) abort
  return s:impl_ns(a:0 ? a:1 : s:buf()) ==# 'cljs' ? 'cljs.user' : 'user'
endfunction

function! s:slash() abort
  return exists('+shellslash') && !&shellslash ? '\' : '/'
endfunction

function! s:includes_file(file, path) abort
  let file = substitute(a:file, '\C^zipfile:\(.*\)::', '\1/', '')
  let file = substitute(file, '\C^fugitive:[\/][\/]\(.*\)\.git[\/][\/][^\/]\+[\/]', '\1', '')
  for path in a:path
    if file[0 : len(path)-1] ==? path
      return 1
    endif
  endfor
endfunction

function! s:path_extract(path, ...) abort
  let path = []
  if a:0 || a:path =~# '\.jar'
    for elem in split(substitute(a:path, ',$', '', ''), a:0 ? '[=,]' : ',')
      if elem ==# ''
        let path += ['.']
      else
        let path += split(glob(substitute(elem, '\\\ze[\\ ,]', '', 'g'), 1), "\n")
      endif
    endfor
  endif
  return path
endfunction

function! fireplace#path(...) abort
  let buf = a:0 ? a:1 : s:buf()
  for repl in s:repls
    if s:includes_file(fnamemodify(bufname(buf), ':p'), repl.path())
      return repl.path()
    endif
  endfor
  return s:path_extract(getbufvar(buf, '&path'))
endfunction

function! fireplace#platform(...) abort
  for [k, v] in items(s:repl_portfiles)
    if getftime(k) != v.time || !has_key(v, 'transport') || !v.transport.alive()
      call s:unregister(get(v, 'transport', get(v, 'connection', {})))
    endif
  endfor

  let portfile = findfile('.nrepl-port', '.;')
  if !empty(portfile)
    call fireplace#register_port_file(portfile, fnamemodify(portfile, ':p:h'))
  endif
  silent doautocmd User FireplacePreConnect

  let buf = a:0 ? a:1 : s:buf()
  let root = simplify(fnamemodify(bufname(buf), ':p:s?[\/]$??'))
  let previous = ""
  while root !=# previous
    if has_key(s:repl_paths, root)
      return s:repl_paths[root]
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile
  for repl in s:repls
    if s:includes_file(fnamemodify(bufname(buf), ':p'), repl.path())
      return repl
    endif
  endfor
  let path = s:path_extract(getbufvar(buf, '&path'))
  if !empty(path) && fnamemodify(bufname(buf), ':e') =~# '^clj[cx]\=$'
    return extend({'_path': path, 'nr': bufnr(buf)}, s:oneoff)
  endif
  throw s:no_repl
endfunction

function! fireplace#client(...) abort
  let buf = a:0 ? a:1 : s:buf()
  let client = fireplace#platform(buf)
  if s:impl_ns(buf) ==# 'cljs'
    if !has_key(client, 'transport')
      throw s:no_repl
    endif
    call filter(client.piggiebacks, 'has_key(v:val, "session")')
    if empty(client.piggiebacks)
      let result = client.piggieback('')
      if has_key(result, 'ex')
        throw 'Fireplace: '.result.ex
      endif
    endif
    return client.piggiebacks[0]
  endif
  return client
endfunction

function! fireplace#message(payload, ...) abort
  let client = fireplace#client()
  let payload = copy(a:payload)
  if !has_key(payload, 'ns')
    let payload.ns = fireplace#ns()
  elseif empty(payload.ns)
    unlet payload.ns
  endif
  if a:0
    return call(client.message, [payload] + a:000, client)
  endif
  throw 'Fireplace: change fireplace#message({...}) to fireplace#message({...}, v:t_list)'
endfunction

function! fireplace#op_available(op) abort
  try
    let client = fireplace#platform()
    if has_key(client, 'transport')
      return client.transport.has_op(a:op)
    endif
  catch /^Fireplace: no live REPL connection/
  endtry
endfunction

function! fireplace#findresource(resource, ...) abort
  if a:resource ==# ''
    return ''
  endif
  let resource = a:resource
  if a:0 > 2 && type(a:3) == type([])
    let suffixes = a:3
  else
    let suffixes = [''] + split(get(a:000, 2, ''), ',')
  endif
  for dir in a:0 ? a:1 : fireplace#path()
    for suffix in suffixes
      if fnamemodify(dir, ':e') ==# 'jar' && index(fireplace#jar_contents(dir), resource . suffix) >= 0
        return 'zipfile:' . dir . '::' . resource . suffix
      elseif filereadable(dir . '/' . resource . suffix)
        return dir . s:slash() . resource . suffix
      endif
    endfor
  endfor
  return ''
endfunction

function! s:output_response(response) abort
  let substitution_pat =  '\e\[[0-9;]*m\|\r\|\n$'
  if get(a:response, 'err', '') !=# ''
    echohl ErrorMSG
    echo substitute(a:response.err, substitution_pat, '', 'g')
    echohl NONE
  endif
  if get(a:response, 'out', '') !=# ''
    echo substitute(a:response.out, substitution_pat, '', 'g')
  endif
endfunction

function! s:eval(expr, ...) abort
  let options = a:0 ? copy(a:1) : {}
  let client = fireplace#client()
  if !has_key(options, 'ns')
    let options.ns = fireplace#ns()
  endif
  return client.eval(a:expr, options)
endfunction

function! s:temp_response(response, ext) abort
  let output = []
  call extend(output, map(split(get(a:response, 'err', ''), "\n"), '";!".v:val'))
  call extend(output, map(split(get(a:response, 'out', ''), "\n"), '";=".v:val'))
  for str in type(get(a:response, 'value')) == v:t_string ? [a:response.value] : get(a:response, 'value', [])
    call extend(output, split(str, "\n"))
  endfor
  let temp = tempname() . '.' . a:ext
  call writefile(output, temp)
  return temp
endfunction

if !exists('s:history')
  let s:history = []
endif

if !exists('s:qffiles')
  let s:qffiles = {}
endif

function! s:qfentry(entry) abort
  if !has_key(a:entry, 'tempfile')
    let a:entry.tempfile = s:temp_response(a:entry.response, get(a:entry, 'ext', 'clj'))
  endif
  let s:qffiles[a:entry.tempfile] = a:entry
  return {'filename': a:entry.tempfile, 'text': a:entry.code, 'type': 'E', 'module': a:entry.response.id}
endfunction

function! s:qfhistory() abort
  let list = []
  for entry in reverse(s:history)
    call extend(list, [s:qfentry(entry)])
  endfor
  return list
endfunction

function! s:stacktrace() abort
  let format_st =
        \ '(let [st (or (when (= "#''cljs.core/str" (str #''str))' .
        \               ' (.-stack *e))' .
        \             ' (.getStackTrace *e))]' .
        \  ' (symbol' .
        \    ' (if (string? st)' .
        \      ' st' .
        \      ' (let [parts (if (= "class [Ljava.lang.StackTraceElement;" (str (type st)))' .
        \                    ' (map str st)' .
        \                    ' (seq (amap st idx ret (str (aget st idx)))))]' .
        \        ' (apply str (interpose "\n" (cons *e parts)))))' .
        \    '))'
  let response = fireplace#message({'op': 'eval', 'code': format_st, 'ns': 'user', 'session': v:true}, v:t_dict)
  return split(response.value[0], "\n", 1)
endfunction

function! fireplace#eval(...) abort
  let opts = {}
  for arg in a:000
    if type(arg) == v:t_string
      let opts.code = arg
    elseif type(arg) == v:t_dict
      call extend(opts, arg)
    elseif type(arg) == v:t_number
      call s:add_pprint_opts(opts, arg)
    endif
  endfor
  let code = remove(opts, 'code')
  let response = s:eval(code, opts)

  call insert(s:history, {'buffer': bufnr(''), 'ext': s:impl_ns() ==# 'cljs' ? 'cljs' : 'clj', 'code': code, 'ns': fireplace#ns(), 'response': response})
  if len(s:history) > &history
    call remove(s:history, &history, -1)
  endif

  if !empty(get(response, 'ex', ''))
    let nr = 0
    if has_key(s:qffiles, expand('%:p'))
      let nr = winbufnr(s:qffiles[expand('%:p')].buffer)
    endif
    let stacktrace = s:stacktrace()
    if nr != -1 && len(stacktrace)
      call setloclist(nr, fireplace#quickfix_for(stacktrace[1:-1]))
      call setloclist(nr, [], 'a', {'title': stacktrace[0]})
    endif
  endif

  try
    silent doautocmd User FireplaceEvalPost
  catch
    echohl ErrorMSG
    echomsg v:exception
    echohl NONE
  endtry

  call s:output_response(response)

  if get(response, 'ex', '') !=# ''
    let err = 'Clojure: '.response.ex
  else
    return get(response, 'value', [])
  endif
  throw err
endfunction

function! fireplace#session_eval(...) abort
  return get(call('fireplace#eval', a:000), -1, '')
endfunction

function! fireplace#echo_session_eval(...) abort
  try
    let values = call('fireplace#eval', [&columns] + a:000)
    if empty(values)
      echohl WarningMsg
      echo "No return value"
      echohl NONE
    else
      for value in values
        echo substitute(value, "\n*$", '', '')
      endfor
    endif
  catch /^Clojure:/
  catch
    echohl ErrorMSG
    echomsg v:exception
    echohl NONE
  endtry
  return ''
endfunction

let g:fireplace#reader =
      \ '(symbol ((fn *vimify [x]' .
      \  ' (cond' .
      \    ' (map? x)     (str "{" (apply str (interpose ", " (map (fn [[k v]] (str (*vimify k) ": " (*vimify v))) x))) "}")' .
      \    ' (coll? x)    (str "[" (apply str (interpose ", " (map *vimify x))) "]")' .
      \    ' (true? x)    "1"' .
      \    ' (false? x)   "0"' .
      \    ' (number? x)  (pr-str x)' .
      \    ' (keyword? x) (pr-str (name x))' .
      \    ' :else        (pr-str (str x)))) %s))'

function! fireplace#evalparse(expr, ...) abort
  let options = extend({'session': 0}, a:0 ? a:1 : {})
  let response = s:eval(printf(g:fireplace#reader, a:expr), options)
  call s:output_response(response)

  if get(response, 'ex', '') !=# ''
    let err = 'Clojure: '.response.ex
  elseif has_key(response, 'value')
    return empty(response.value) ? '' : eval(response.value[0])
  else
    let err = 'fireplace.vim: No value in '.string(response)
  endif
  throw err
endfunction

function! fireplace#query(expr, ...) abort
  return fireplace#evalparse(a:expr, a:0 ? a:1 : {})
endfunction

" Section: Quickfix

function! s:qfmassage(line, path) abort
  let entry = {'text': a:line}
  let match = matchlist(a:line, '^\s*\(\S\+\)\s\=(\([^:()[:space:]]*\)\%(:\(\d\+\)\)\=)$')
  if !empty(match)
    let [_, class, file, lnum; __] = match
    let entry.module = class
    let entry.lnum = +lnum
    if file ==# 'NO_SOURCE_FILE' || !lnum
      let entry.resource = ''
    else
      let truncated = substitute(class, '\.[A-Za-z0-9_]\+\%([$/].*\)$', '', '')
      let entry.resource = tr(truncated, '.', '/') . '/' . file
    endif
    let entry.filename = fireplace#findresource(entry.resource, a:path)
    if has('patch-8.0.1782')
      let entry.text = ''
    else
      let entry.text = class
    endif
  endif
  return entry
endfunction

function! fireplace#quickfix_for(stacktrace) abort
  let path = fireplace#path()
  return map(copy(a:stacktrace), 's:qfmassage(v:val, path)')
endfunction

function! fireplace#massage_list(...) abort
  let p = substitute(matchstr(','.&errorformat, '\C,\%(%\\&\)\=classpath=\=\zs\%(\\.\|[^\,]\)*'), '\\\ze[\,%]', '', 'g')
  if empty(p)
    return
  endif
  if a:0
    let GetList = function('getloclist', [a:1])
    let SetList = function('setloclist', [a:1])
  else
    let GetList = function('getqflist', [])
    let SetList = function('setqflist', [])
  endif
  let path = p =~# '^[:;]' ? split(p[1:-1], p[0]) : p[0] ==# ',' ? s:path_extract(p[1:-1], 1) : s:path_extract(p, 1)
  let qflist = GetList()
  for entry in qflist
    call extend(entry, s:qfmassage(get(entry, 'text', ''), path))
  endfor
  let attrs = GetList({'title': 1})
  call SetList(qflist, 'r')
  call SetList([], 'r', attrs)
endfunction

" Section: Eval

let fireplace#skip = 'synIDattr(synID(line("."),col("."),1),"name") =~? "comment\\|string\\|char\\|regexp"'

function! s:opfunc(type) abort
  let sel_save = &selection
  let cb_save = &clipboard
  let reg_save = @@
  try
    set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
    if type(a:type) == type(0)
      let open = '[[{(]'
      let close = '[]})]'
      if getline('.')[col('.')-1] =~# close
        let [line1, col1] = searchpairpos(open, '', close, 'bn', g:fireplace#skip)
        let [line2, col2] = [line('.'), col('.')]
      else
        let [line1, col1] = searchpairpos(open, '', close, 'bcn', g:fireplace#skip)
        let [line2, col2] = searchpairpos(open, '', close, 'n', g:fireplace#skip)
      endif
      while col1 > 1 && getline(line1)[col1-2] =~# '[#''`~@]'
        let col1 -= 1
      endwhile
      call setpos("'[", [0, line1, col1, 0])
      call setpos("']", [0, line2, col2, 0])
      silent exe "normal! `[v`]y"
    elseif a:type =~# '^.$'
      silent exe "normal! `<" . a:type . "`>y"
    elseif a:type ==# 'line'
      silent exe "normal! '[V']y"
    elseif a:type ==# 'block'
      silent exe "normal! `[\<C-V>`]y"
    elseif a:type ==# 'outer'
      call searchpair('(','',')', 'Wbcr', g:fireplace#skip)
      silent exe "normal! vaby"
    else
      silent exe "normal! `[v`]y"
    endif
    redraw
    return {'code': @@, 'file': s:buffer_path(), 'line': line("'<"), 'column': col("'<")}
  finally
    let @@ = reg_save
    let &selection = sel_save
    let &clipboard = cb_save
  endtry
endfunction

function! s:filterop(type) abort
  let reg_save = @@
  let sel_save = &selection
  let cb_save = &clipboard
  try
    set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
    let opts = s:opfunc(a:type)
    let @@ = matchstr(opts.code, '^\n\+') . join(fireplace#eval(opts), ' ') . matchstr(opts.code, '\n\+$')
    if @@ !~# '^\n*$'
      normal! gvp
    endif
  catch /^Clojure:/
    return ''
  finally
    let @@ = reg_save
    let &selection = sel_save
    let &clipboard = cb_save
  endtry
endfunction

function! s:macroexpand(fn, form) abort
  return fireplace#echo_session_eval('('.a:fn.' (quote '.a:form.'))')
endfunction

function! s:macroexpandop(type) abort
  call s:macroexpand("clojure.walk/macroexpand-all", s:opfunc(a:type).code)
endfunction

function! s:macroexpand1op(type) abort
  call s:macroexpand("macroexpand-1", s:opfunc(a:type).code)
endfunction

function! s:printop(type) abort
  let s:todo = s:opfunc(a:type)
  call feedkeys("\<Plug>FireplacePrintLast")
endfunction

function! s:add_pprint_opts(msg, width) abort
  let a:msg['nrepl.middleware.print/stream?'] = 1
  if fireplace#op_available('info')
    let a:msg['nrepl.middleware.print/print'] = 'cider.nrepl.pprint/fipp-pprint'
    let a:msg['nrepl.middleware.print/options'] = {}
    if a:width > 0
      let a:msg['nrepl.middleware.print/options'].width = a:width
    endif
  endif
  return a:msg
endfunction

function! s:print_last() abort
  call fireplace#echo_session_eval(s:todo)
  return ''
endfunction

function! s:editop(type) abort
  call feedkeys(eval('"\'.&cedit.'"') . "\<Home>", 'n')
  let input = s:input(substitute(substitute(substitute(
        \ s:opfunc(a:type).code, "\s*;[^\n\"]*\\%(\n\\@=\\|$\\)", '', 'g'),
        \ '\n\+\s*', ' ', 'g'),
        \ '^\s*', '', ''))
  if input !=# ''
    call fireplace#echo_session_eval(input)
  endif
endfunction

function! s:Eval(bang, line1, line2, count, args) abort
  let options = {}
  if a:args !=# ''
    let expr = a:args
  else
    if a:count ==# 0
      let open = '[[{(]'
      let close = '[]})]'
      let [line1, col1] = searchpairpos(open, '', close, 'bcrn', g:fireplace#skip)
      let [line2, col2] = searchpairpos(open, '', close, 'rn', g:fireplace#skip)
      if !line1 && !line2
        let [line1, col1] = searchpairpos(open, '', close, 'brn', g:fireplace#skip)
        let [line2, col2] = searchpairpos(open, '', close, 'crn', g:fireplace#skip)
      endif
      while col1 > 1 && getline(line1)[col1-2] =~# '[#''`~@]'
        let col1 -= 1
      endwhile
    else
      let line1 = a:line1
      let line2 = a:line2
      let col1 = 1
      let col2 = strlen(getline(line2))
    endif
    if !line1 || !line2
      return ''
    endif
    let options.file = s:buffer_path()
    let options.line = line1
    let options.column = col1
    if line1 == line2
      let expr = getline(line1)[col1-1 : col2-1]
    else
      let expr = getline(line1)[col1-1 : -1] . "\n"
            \ . join(map(getline(line1+1, line2-1), 'v:val . "\n"'))
            \ . getline(line2)[0 : col2-1]
    endif
    if a:bang
      exe line1.','.line2.'delete _'
    endif
  endif
  if a:bang
    try
      let result = split(join(map(fireplace#eval(expr, &textwidth, options), 'substitute(v:val, "\n*$", "", "")'), "\n"), "\n")
      if a:args !=# ''
        call append(a:line1, result)
        exe a:line1
      else
        call append(a:line1-1, result)
        exe a:line1-1
      endif
    catch /^Clojure:/
    endtry
  else
    call fireplace#echo_session_eval(expr, options)
  endif
  return ''
endfunction

" If we call input() directly inside a try, and the user opens the command
" line window and tries to switch out of it (such as with ctrl-w), Vim will
" crash when the command line window closes.  Adding an indirect function call
" works around this.
function! s:actually_input(...) abort
  return call(function('input'), a:000)
endfunction

function! s:input(default) abort
  if !exists('g:FIREPLACE_HISTORY') || type(g:FIREPLACE_HISTORY) != type([])
    unlet! g:FIREPLACE_HISTORY
    let g:FIREPLACE_HISTORY = []
  endif
  try
    let s:input = bufnr('%')
    let s:oldhist = s:histswap(g:FIREPLACE_HISTORY)
    return s:actually_input(fireplace#ns().'=> ', a:default, 'customlist,fireplace#eval_complete')
  finally
    unlet! s:input
    if exists('s:oldhist')
      let g:FIREPLACE_HISTORY = s:histswap(s:oldhist)
    endif
  endtry
endfunction

function! s:inputclose() abort
  let l = substitute(getcmdline(), '"\%(\\.\|[^"]\)*"\|\\.', '', 'g')
  let open = len(substitute(l, '[^(]', '', 'g'))
  let close = len(substitute(l, '[^)]', '', 'g'))
  if open - close == 1
    return ")\<CR>"
  else
    return ")"
  endif
endfunction

function! s:inputeval() abort
  let input = s:input('')
  redraw
  if input !=# ''
    call fireplace#echo_session_eval(input)
  endif
  return ''
endfunction

function! s:recall() abort
  try
    cnoremap <expr> ) <SID>inputclose()
    let input = s:input('(')
    if input =~# '^(\=$'
      return ''
    else
      return join(fireplace#eval(input), ' ')
    endif
  catch /^Clojure:/
    return ''
  finally
    silent! cunmap )
  endtry
endfunction

function! s:histswap(list) abort
  let old = []
  for i in range(1, histnr('@') * (histnr('@') > 0))
    call extend(old, [histget('@', i)])
  endfor
  call histdel('@')
  for entry in a:list
    call histadd('@', entry)
  endfor
  return old
endfunction

nnoremap <silent> <Plug>FireplacePrintLast :exe <SID>print_last()<CR>
nnoremap <silent> <Plug>FireplacePrint  :<C-U>set opfunc=<SID>printop<CR>g@
xnoremap <silent> <Plug>FireplacePrint  :<C-U>call <SID>printop(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceCountPrint  :<C-U>call <SID>printop(v:count)<CR>

nnoremap <silent> <Plug>FireplaceFilter :<C-U>set opfunc=<SID>filterop<CR>g@
xnoremap <silent> <Plug>FireplaceFilter :<C-U>call <SID>filterop(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceCountFilter :<C-U>call <SID>filterop(v:count)<CR>

nnoremap <silent> <Plug>FireplaceMacroExpand  :<C-U>set opfunc=<SID>macroexpandop<CR>g@
xnoremap <silent> <Plug>FireplaceMacroExpand  :<C-U>call <SID>macroexpandop(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceCountMacroExpand  :<C-U>call <SID>macroexpandop(v:count)<CR>
nnoremap <silent> <Plug>Fireplace1MacroExpand :<C-U>set opfunc=<SID>macroexpand1op<CR>g@
xnoremap <silent> <Plug>Fireplace1MacroExpand :<C-U>call <SID>macroexpand1op(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceCount1MacroExpand :<C-U>call <SID>macroexpand1op(v:count)<CR>

nnoremap <silent> <Plug>FireplaceEdit   :<C-U>set opfunc=<SID>editop<CR>g@
xnoremap <silent> <Plug>FireplaceEdit   :<C-U>call <SID>editop(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceCountEdit :<C-U>call <SID>editop(v:count)<CR>

nnoremap          <Plug>FireplacePrompt :exe <SID>inputeval()<CR>

noremap!          <Plug>FireplaceRecall <C-R>=<SID>recall()<CR>

function! s:Last(bang, count) abort
  if len(s:history) < a:count
    return 'echoerr "History entry not found"'
  endif
  let history = s:qfhistory()
  let last = s:qfhistory()[a:count-1]
  execute 'pedit '.last.filename
  if !&previewwindow
    let nr = winnr()
    wincmd p
    wincmd P
  endif
  call setloclist(0, history)
  silent exe 'llast '.(len(history)-a:count+1)
  if exists('nr') && a:bang
    wincmd p
    exe nr.'wincmd w'
  endif
  return ''
endfunction

function! s:set_up_eval() abort
  command! -buffer -bang -range=0 -nargs=? -complete=customlist,fireplace#eval_complete Eval :exe s:Eval(<bang>0, <line1>, <line2>, <count>, <q-args>)
  command! -buffer -bang -bar -count=1 Last exe s:Last(<bang>0, <count>)
  command! -buffer -bang -bar Stacktrace lopen

  if get(g:, 'fireplace_no_maps') | return | endif

  call s:map('n', 'cp', '<Plug>FireplacePrint')
  call s:map('n', 'cpp', '<Plug>FireplaceCountPrint')

  call s:map('n', 'c!', '<Plug>FireplaceFilter')
  call s:map('n', 'c!!', '<Plug>FireplaceCountFilter')

  call s:map('n', 'cm', '<Plug>FireplaceMacroExpand')
  call s:map('n', 'cmm', '<Plug>FireplaceCountMacroExpand')
  call s:map('n', 'c1m', '<Plug>Fireplace1MacroExpand')
  call s:map('n', 'c1mm', '<Plug>FireplaceCount1MacroExpand')

  call s:map('n', 'cq', '<Plug>FireplaceEdit')
  call s:map('n', 'cqq', '<Plug>FireplaceCountEdit')

  call s:map('n', 'cqp', '<Plug>FireplacePrompt')
  call s:map('n', 'cqc', '<Plug>FireplacePrompt' . &cedit . 'i')

  call s:map('i', '<C-R>(', '<Plug>FireplaceRecall')
  call s:map('c', '<C-R>(', '<Plug>FireplaceRecall')
  call s:map('s', '<C-R>(', '<Plug>FireplaceRecall')
endfunction

function! s:set_up_historical() abort
  setlocal readonly nomodifiable
  call s:map('n', 'q', ':bdelete<CR>', '<silent>')
endfunction

function! s:cmdwinenter() abort
  setlocal filetype=clojure
endfunction

function! s:cmdwinleave() abort
  setlocal filetype< omnifunc<
endfunction

augroup fireplace_eval
  autocmd!
  autocmd BufReadPost * if has_key(s:qffiles, expand('<amatch>:p')) |
        \   call s:set_up_historical() |
        \ endif
  autocmd CmdWinEnter @ if exists('s:input') | call s:cmdwinenter() | endif
  autocmd CmdWinLeave @ if exists('s:input') | call s:cmdwinleave() | endif
augroup END

" Section: :Require

function! s:Require(bang, echo, ns) abort
  if &autowrite || &autowriteall
    silent! wall
  endif
  if s:impl_ns() ==# 'cljs'
    let cmd = '(load-file '.s:str(tr(a:ns ==# '' ? fireplace#ns() : a:ns, '-.', '_/').'.cljs').')'
  else
    let cmd = ('(clojure.core/require '.s:qsym(a:ns ==# '' ? fireplace#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').')')
  endif
  if a:echo
    echo cmd
  endif
  try
    call fireplace#eval(cmd, {'ns': s:user_ns()})
    return ''
  catch /^Clojure:.*/
    return ''
  endtry
endfunction

function! s:set_up_require() abort
  command! -buffer -bar -bang -complete=customlist,fireplace#ns_complete -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)

  call s:map('n', 'cpr', ":<C-R>=<SID>impl_ns() ==# 'cljs' ? 'Require' : 'RunTests'<CR><CR>", '<silent>')
endfunction

" Section: Go to source

function! fireplace#info(symbol) abort
  if fireplace#op_available('info')
    let response = fireplace#message({'op': 'info', 'symbol': a:symbol}, v:t_dict)
    if type(get(response, 'value')) == type({})
      return response.value
    elseif has_key(response, 'file') || has_key(response, 'doc')
      return response
    endif
  endif

  let sym = s:qsym(a:symbol)
  let cmd =
        \ '(cond'
        \ . '(not (symbol? ' . sym . '))'
        \ . '{}'
        \ . '(special-symbol? ' . sym . ')'
        \ . "(if-let [m (#'clojure.repl/special-doc " . sym . ")]"
        \ .   ' {:name (:name m)'
        \ .    ' :special-form "true"'
        \ .    ' :doc (:doc m)'
        \ .    ' :url (:url m)'
        \ .    ' :forms-str (str "  " (:forms m))}'
        \ .   ' {})'
        \ . '(find-ns ' . sym . ')'
        \ . "(if-let [m (#'clojure.repl/namespace-doc (find-ns " . sym . "))]"
        \ .   ' {:ns (:name m)'
        \ .   '  :doc (:doc m)}'
        \ .   ' {})'
        \ . ':else'
        \ . '(if-let [m (meta (resolve ' . sym .'))]'
        \ .   ' {:name (:name m)'
        \ .    ' :ns (:ns m)'
        \ .    ' :macro (when (:macro m) true)'
        \ .    ' :resource (:file m)'
        \ .    ' :line (:line m)'
        \ .    ' :doc (:doc m)'
        \ .    ' :arglists-str (str (:arglists m))}'
        \ .   ' {})'
        \ . ' )'
  return fireplace#evalparse(cmd)
endfunction

function! fireplace#source(symbol) abort
  let info = fireplace#info(a:symbol)

  let file = ''
  if !empty(get(info, 'resource'))
    let file = fireplace#findresource(info.resource)
  elseif get(info, 'file', '') =~# '^file:'
    let file = substitute(strpart(info.file, 5), '/', s:slash(), 'g')
  else
    let file = get(info, 'file', '')
  endif

  if !empty(file) && !empty(get(info, 'line', ''))
    return '+' . info.line . ' ' . fnameescape(file)
  endif
  return ''
endfunction

function! fireplace#location(keyword) abort
  if a:keyword =~# '^\k\+[/.]$'
    return fireplace#findfile(a:keyword[0: -2])
  elseif a:keyword =~# '^\k\+\.[^/.]\+$'
    return fireplace#findfile(a:keyword)
  else
    return fireplace#source(a:keyword)
  endif
endfunction

function! s:Edit(cmd, keyword) abort
  try
    let location = fireplace#location(a:keyword)
  catch /^Clojure:/
    return ''
  endtry
  if location !=# ''
    if matchstr(location, '^+\d\+ \zs.*') ==# fnameescape(expand('%:p')) && a:cmd ==# 'edit'
      normal! m'
      return matchstr(location, '\d\+')
    else
      return substitute(a:cmd, '^\%(<mods>\)\= ', '', '') . ' ' . location .
            \ '|let &l:path = ' . string(&l:path)
    endif
  endif
  let v:errmsg = "Couldn't find source for ".a:keyword
  return 'echoerr v:errmsg'
endfunction

nnoremap <silent> <Plug>FireplaceDjump :<C-U>exe <SID>Edit('edit', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceDsplit :<C-U>exe <SID>Edit('split', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceDtabjump :<C-U>exe <SID>Edit('tabedit', <SID>cword())<CR>

function! s:set_up_source() abort
  setlocal define=^\\s*(def\\w*
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Djump  :exe s:Edit('edit', <q-args>)
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Dsplit :exe s:Edit('<mods> split', <q-args>)

  call s:map('n', '[<C-D>',     '<Plug>FireplaceDjump')
  call s:map('n', ']<C-D>',     '<Plug>FireplaceDjump')
  call s:map('n', '<C-W><C-D>', '<Plug>FireplaceDsplit')
  call s:map('n', '<C-W>d',     '<Plug>FireplaceDsplit')
  call s:map('n', '<C-W>gd',    '<Plug>FireplaceDtabjump')
endfunction

" Section: Go to file

function! fireplace#findfile(path) abort
  let path = a:path
  if a:path !~# '/'
    let path = tr(a:path, '.-', '/_')
  else
    let path = substitute(a:path, '^/', '', '')
  endif
  let resource = fireplace#findresource(path, fireplace#path(), 0, &suffixesadd)
  if !empty(resource)
    return resource
  elseif fnamemodify(a:path, ':p') ==# a:path && filereadable(a:path)
    return path
  elseif a:path[0] !=# '/' && filereadable(expand('%:h') . '/' . path)
    return expand('%:h') . '/' . path
  endif
  return ''
endfunction

let s:iskeyword = '[[:alnum:]_=?!#$%&*+|./<>:''-]'
let s:token = '^\%(#"\%(\\\@<!\%(\\\\\)*\\"\|[^"]\)*"\|"\%(\\.\|[^"]\)*"\|[[:space:],]\+\|\%(;\|#!\)[^'."\n".']*\|\~@\|#[[:punct:]]\|''\@!'.s:iskeyword.'\+\|\\\%(space\|tab\|newline\|return\|.\)\|.\)'
function! s:read_token(str, pos) abort
  let pos = a:pos
  let match = ' '
  while match =~# '^[[:space:],;]'
    let match = matchstr(a:str, s:token, pos)
    let pos += len(match)
  endwhile
  if empty(match)
    throw 'Fireplace: Clojure parse error'
  endif
  return [match, pos]
endfunction

function! s:read(str, pos) abort
  let [token, pos] = s:read_token(a:str, a:pos)
  if token =~# '^#\=[[{(]'
    let list = []
    while index([')', ']', '}', ''], get(list, -1)) < 0
      unlet token
      let [token, pos] = s:read(a:str, pos)
      call add(list, token)
    endwhile
    call remove(list, -1)
    return [list, pos]
  elseif token ==# '#_'
    let pos = s:read(a:str, pos)[1]
    return s:read(a:str, pos)
  else
    return [token, pos]
  endif
endfunction

function! s:ns(...) abort
  let buffer = a:0 ? a:1 : s:buf()
  let head = getbufline(buffer, 1, 1000)
  let blank = '^\s*\%(;.*\)\=$'
  call filter(head, 'v:val !~# blank')
  let lines = join(head, "\n")
  let match = matchstr(lines, '\C^(\s*ns\s\+.*')
  if len(match)
    try
      return s:read(match, 0)[0]
    catch /^Fireplace: Clojure parse error$/
    endtry
  endif
  return []
endfunction

function! fireplace#resolve_alias(name) abort
  let _ = {}
  for refs in filter(copy(s:ns()), 'type(v:val) == type([])')
    if a:name =~# '^\u' && get(refs, 0) is# ':import'
      for _.ref in refs
        if type(_.ref) == type([]) && index(_.ref, a:name) > 0
          return _.ref[0] . '.' . a:name
        elseif type(_.ref) == type('') && _.ref =~# '\.'.a:name.'$'
          return _.ref
        endif
      endfor
    endif
    if get(refs, 0) is# ':require'
      for _.ref in refs
        if type(_.ref) == type([])
          let i = index(_.ref, ':as')
          if i > 0 && get(_.ref, i+1) ==# a:name
            return _.ref[0]
          endif
          for nref in filter(copy(_.ref), 'type(v:val) == type([])')
            let i = index(nref, ':as')
            if i > 0 && get(nref, i+1) ==# a:name
              return _.ref[0].'.'.nref[0]
            endif
          endfor
        endif
      endfor
    endif
  endfor
  return a:name
endfunction

function! fireplace#cfile() abort
  let isfname = &isfname
  try
    set isfname+='
    let file = substitute(expand('<cfile>'), "^''*", '', '')
  finally
    let isfname = &isfname
  endtry
  if file =~# '^\w[[:alnum:]_/]*$' &&
        \ synIDattr(synID(line("."),col("."),1),"name") =~# 'String'
    let file = substitute(expand('%:p'), '[^\/:]*$', '', '').file
  elseif file =~# '^[^/]*/[^/.]*$' && file =~# '^\%(\k\|''\)\+$'
    let [file, jump] = split(file, "/")
    let file = fireplace#resolve_alias(file)
    if file !~# '\.' && fireplace#op_available('info')
      let res = fireplace#message({'op': 'info', 'symbol': file}, v:t_dict)
      let file = get(res, 'ns', file)
    endif
    let file = tr(file, '.-', '/_')
  elseif file =~# '^\w[[:alnum:].-]*''\=$'
    let file = tr(fireplace#resolve_alias(file), '.-', '/_')
  endif
  if exists('jump')
    return '+sil!dj\ ' . jump . ' ' . fnameescape(file)
  else
    return fnameescape(file)
  endif
endfunction

function! s:Find(find, edit) abort
  let cfile = fireplace#cfile()
  let prefix = matchstr(cfile, '^\%(+\%(\\.\|\S\)*\s\+\)')
  let file = fireplace#findfile(expand(strpart(cfile, len(prefix))))
  if file =~# '^zipfile:'
    let setpath = 'let\ &l:path=getbufvar('.bufnr('').",'&path')"
    if prefix =~# '^+[^+]'
      let prefix = substitute(prefix, '+', '\="+".setpath."\\|"', '')
    else
      let prefix = '+'.setpath.' '.prefix
    endif
  endif
  if len(file)
    return (len(a:edit) ? a:edit . ' ' : '') . prefix . fnameescape(file)
  else
    return len(a:find) ? a:find . ' ' . cfile : "\<C-R>\<C-P>"
  endif
endfunction

nnoremap <silent> <Plug>FireplaceEditFile    :<C-U>exe <SID>Find('find','edit')<CR>
nnoremap <silent> <Plug>FireplaceSplitFile   :<C-U>exe <SID>Find('sfind','split')<CR>
nnoremap <silent> <Plug>FireplaceTabeditFile :<C-U>exe <SID>Find('tabfind','tabedit')<CR>

function! s:set_up_go_to_file() abort
  if expand('%:e') ==# 'cljs'
    setlocal suffixesadd=.cljs,.cljc,.cljx,.clj,.java
  else
    setlocal suffixesadd=.clj,.cljc,.cljx,.cljs,.java
  endif

  cmap <buffer><script><expr> <Plug><cfile> substitute(fireplace#cfile(),'^$',"\022\006",'')
  cmap <buffer><script><expr> <Plug><cpath> <SID>Find('','')
  if get(g:, 'fireplace_no_maps') | return | endif
  call s:map('c', '<C-R><C-F>', '<Plug><cfile>')
  call s:map('c', '<C-R><C-P>', '<Plug><cpath>')
  call s:map('n', 'gf',         '<Plug>FireplaceEditFile',    '<unique>')
  call s:map('n', '<C-W>f',     '<Plug>FireplaceSplitFile',   '<unique>')
  call s:map('n', '<C-W><C-F>', '<Plug>FireplaceSplitFile',   '<unique>')
  call s:map('n', '<C-W>gf',    '<Plug>FireplaceTabeditFile', '<unique>')
endfunction

" Section: Spec

function! fireplace#qualify_keyword(kw) abort
  if a:kw =~# '^::.\+/'
    let kw = ':' . fireplace#resolve_alias(matchstr(a:kw, '^::\zs[^/]\+')) . matchstr(a:kw, '/.*')
  elseif a:kw =~# '^::'
    let kw = ':' . fireplace#ns() . '/' . strpart(a:kw, 2)
  else
    let kw = a:kw
  endif
  return kw
endfunction

function! s:SpecForm(kw) abort
  let op = "spec-form"
  try
    let symbol = fireplace#qualify_keyword(a:kw)
    let response = fireplace#message({'op': op, 'spec-name': symbol}, v:t_dict)
    if !empty(get(response, op))
      echo s:pr(get(response, op))
    elseif has_key(response, 'op')
      return 'echoerr ' . string('Fireplace: no nREPL op available for ' . op)
    endif
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
  return ''
endfunction

function! s:SpecExample(kw) abort
  let op = "spec-example"
  try
    let symbol = fireplace#qualify_keyword(a:kw)
    let response = fireplace#message({'op': op, 'spec-name': symbol}, v:t_dict)
    if !empty(get(response, op))
      echo get(response, op)
    elseif has_key(response, 'op')
      return 'echoerr ' . string('Fireplace: no nREPL op available for ' . op)
    endif
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
  return ''
endfunction

function! s:set_up_spec() abort
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete SpecForm    :exe s:SpecForm(<q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete SpecExample :exe s:SpecExample(<q-args>)
endfunction

" Section: Formatting

function! fireplace#format(lnum, count, char) abort
  if mode() =~# '[iR]' || getline(a:lnum) =~# '^\s*;'
    return -1
  endif
  let reg_save = @@
  let sel_save = &selection
  let cb_save = &clipboard
  try
    set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
    silent exe "normal! " . string(a:lnum) . "ggV" . string(a:count-1) . "jy"
    let code = @@
    let response = fireplace#message({'op': 'format-code', 'code': code}, v:t_dict)
    if !empty(get(response, 'formatted-code'))
      let @@ = get(response, 'formatted-code')
      if @@ !~# '^\n*$' && @@ !=# code
        normal! gvp
      endif
    endif
  finally
    let @@ = reg_save
    let &selection = sel_save
    let &clipboard = cb_save
  endtry
endfunction

" Section: Documentation

function! s:Lookup(ns, macro, arg) abort
  try
    let response = s:eval('('.a:ns.'/'.a:macro.' '.a:arg.')', {'session': ''})
    call s:output_response(response)
  catch /^Clojure:/
  catch /.*/
    echohl ErrorMSG
    echo v:exception
    echohl None
  endtry
  return ''
endfunction

function! s:inputlist(label, entries) abort
  let choices = [a:label]
  for i in range(len(a:entries))
    let choices += [printf('%2d. %s', i+1, a:entries[i])]
  endfor
  let choice = inputlist(choices)
  if choice
    return a:entries[choice-1]
  else
    return ''
  endif
endfunction

function! s:Doc(symbol) abort
  let info = fireplace#info(a:symbol)
  if has_key(info, 'ns') && has_key(info, 'name')
    echo info.ns . '/' . info.name
  elseif has_key(info, 'ns')
    echo info.ns
  elseif has_key(info, 'name')
    echo info.name
  endif

  if get(info, 'forms-str', 'nil') !=# 'nil'
    echo info['forms-str']
  endif

  if get(info, 'arglists-str', '') !=# ''
    echo info['arglists-str']
  endif

  if get(info, 'special-form', 'nil') !=# 'nil'
    echo "Special Form"

    if has_key(info, 'url')
      if !empty(get(info, 'url', ''))
        echo '  Please see http://clojure.org/' . info.url
      else
        echo '  Please see http://clojure.org/special_forms#' . info.name
      endif
    endif

  elseif get(info, 'macro', '') !=# ''
    echo "Macro"
  endif

  if !empty(get(info, 'doc', ''))
    echo '  ' . info.doc
  endif

  return ''
endfunction

function! s:K() abort
  let word = s:cword()
  let java_candidate = matchstr(word, '^\%(\w\+\.\)*\u\l[[:alnum:]$]*\ze\%(\.\|\/\w\+\)\=$')
  if java_candidate !=# ''
    return 'Javadoc '.java_candidate
  elseif word =~# '^:'
    return 'SpecForm '.word
  else
    return 'Doc '.word
  endif
endfunction

nnoremap <Plug>FireplaceK :<C-R>=<SID>K()<CR><CR>
nnoremap <Plug>FireplaceSource :Source <C-R>=<SID>cword()<CR><CR>

function! s:set_up_doc() abort
  command! -buffer -nargs=1 FindDoc :exe s:Lookup(s:repl_ns(), 'find-doc', printf('#"%s"', <q-args>))
  command! -buffer -bar -nargs=1 Javadoc :exe s:Lookup('clojure.java.javadoc', 'javadoc', <q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Doc     :exe s:Doc(<q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Source  :exe s:Lookup(s:repl_ns(), 'source', <q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Dlist   :exe s:Lookup(s:repl_ns(), 'source', <q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Dsearch :exe s:Lookup(s:repl_ns(), 'source', <q-args>)
  setlocal keywordprg=:Doc

  call s:map('n', 'K', '<Plug>FireplaceK', '<unique>')
  call s:map('n', '[d', '<Plug>FireplaceSource')
  call s:map('n', ']d', '<Plug>FireplaceSource')
endfunction

" Section: Tests

function! s:capture_test_run(expr, pre, bang) abort
  let expr = '(try'
        \ . ' ' . a:pre
        \ . ' (clojure.core/require ''clojure.test)'
        \ . ' (clojure.core/binding [clojure.test/report (fn [m]'
        \ .  ' (clojure.core/case (:type m)'
        \ .    ' (:fail :error)'
        \ .    ' (clojure.core/let [{file :file line :line test :name} (clojure.core/meta (clojure.core/last clojure.test/*testing-vars*))]'
        \ .      ' (clojure.test/with-test-out'
        \ .        ' (clojure.test/inc-report-counter (:type m))'
        \ .        ' (clojure.core/println (clojure.string/join "\t" [file line (clojure.core/name (:type m)) test]))'
        \ .        ' (clojure.core/when (clojure.core/seq clojure.test/*testing-contexts*) (clojure.core/println (clojure.test/testing-contexts-str)))'
        \ .        ' (clojure.core/when-let [message (:message m)] (clojure.core/println message))'
        \ .        ' (clojure.core/println "expected:" (clojure.core/pr-str (:expected m)))'
        \ .        ' (clojure.core/println "  actual:" (clojure.core/pr-str (:actual m)))))'
        \ .    ' ((.getRawRoot #''clojure.test/report) m)))]'
        \ . ' ' . a:expr . ')'
        \ . ' (catch Exception e'
        \ . '   (clojure.core/println (clojure.core/str e))'
        \ . '   (clojure.core/println (clojure.string/join "\n" (.getStackTrace e)))))'
  call setqflist([], ' ', {'title': a:expr})
  echo 'Started: ' . a:expr
  call fireplace#message({'op': 'eval', 'code': expr, 'session': 0},
        \ function('s:handle_test_response', [[], get(getqflist({'id': 0}), 'id'), fireplace#path(), a:expr, a:bang]))
endfunction

function! s:handle_test_response(buffer, id, path, expr, bang, message) abort
  let str = get(a:message, 'out', '') . get(a:message, 'err', '')
  if empty(a:buffer)
    let str = substitute(str, "^\r\\=\n", "", "")
    call add(a:buffer, '')
  endif
  let lines = split(a:buffer[0] . str, "\r\\=\n", 1)
  if !has_key(a:message, 'status') || empty(lines[-1])
    let a:buffer[0] = remove(lines, -1)
  else
    let a:buffer[0] = ''
  endif
  let entries = []
  for line in lines
    if line =~# '\t.*\t.*\t'
      let entry = {'text': line}
      let [resource, lnum, type, name] = split(line, "\t", 1)
      let entry.lnum = lnum
      let entry.type = (type ==# 'fail' ? 'W' : 'E')
      let entry.text = name
      if resource ==# 'NO_SOURCE_FILE'
        let resource = ''
        let entry.lnum = 0
      endif
      let entry.filename = fireplace#findresource(resource, a:path)
      if empty(entry.filename)
        let entry.lnum = 0
      endif
    else
      let entry = s:qfmassage(line, a:path)
    endif
    call add(entries, entry)
  endfor
  if a:id
    call setqflist([], 'a', {'id': a:id, 'items': entries})
  else
    call setqflist(entries, 'a')
  endif
  if has_key(a:message, 'status')
    if !a:bang && get(getqflist({'id': 0}), 'id') ==# a:id
      let my_winid = win_getid()
      botright cwindow
      if my_winid !=# win_getid()
        call win_gotoid(my_winid)
      endif
    endif
    let list = a:id ? getqflist({'id': a:id, 'items': 1}).items : getqflist()
    redraw
    if empty(filter(list, 'v:val.valid'))
      echo 'Success: ' . a:expr
    else
      echo 'Failure: ' . a:expr
    endif
  endif
endfunction

function! s:RunTests(bang, count, ...) abort
  if &autowrite || &autowriteall
    silent! wall
  endif
  if a:count < 0
    let pre = ''
    if a:0
      let expr = ['(clojure.test/run-all-tests #"'.join(a:000, '|').'")']
    else
      let expr = ['(clojure.test/run-all-tests)']
    endif
  else
    if a:0 && a:000 !=# [fireplace#ns()]
      let args = a:000
    else
      let args = [fireplace#ns()]
      if a:count
        let pattern = '^\s*(def\k*\s\+\(\h\k*\)'
        let line = search(pattern, 'bcWn')
        if line
          let args[0] .= '/' . matchlist(getline(line), pattern)[1]
        endif
      endif
    endif
    let reqs = map(copy(args), '"''".v:val')
    let pre = '(clojure.core/require '.substitute(join(reqs, ' '), '/\k\+', '', 'g').' :reload) '
    let expr = []
    let vars = filter(copy(reqs), 'v:val =~# "/"')
    let nses = filter(copy(reqs), 'v:val !~# "/"')
    if len(vars) == 1
      call add(expr, '(clojure.test/test-vars [#' . vars[0] . '])')
    elseif !empty(vars)
      call add(expr, join(['(clojure.test/test-vars'] + map(vars, '"#".v:val'), ' ').')')
    endif
    if !empty(nses)
      call add(expr, join(['(clojure.test/run-tests'] + nses, ' ').')')
    endif
  endif
  call s:capture_test_run(join(expr, ' '), pre, a:bang)
endfunction

function! s:set_up_tests() abort
  command! -buffer -bar -bang -range=0 -nargs=*
        \ -complete=customlist,fireplace#ns_complete RunTests
        \ call s:RunTests(<bang>0, <line1> == 0 ? -1 : <count>, <f-args>)
  command! -buffer -bang -nargs=* RunAllTests
        \ call s:RunTests(<bang>0, -1, <f-args>)
endfunction

" Section: Activation

function! fireplace#activate() abort
  setlocal omnifunc=fireplace#omnicomplete
  setlocal formatexpr=fireplace#format(v:lnum,v:count,v:char)
  call s:set_up_connect()
  call s:set_up_eval()
  call s:set_up_require()
  call s:set_up_source()
  call s:set_up_go_to_file()
  call s:set_up_spec()
  call s:set_up_doc()
  call s:set_up_tests()
  if exists('#User#FireplaceActivate')
    doautocmd <nomodeline> User FireplaceActivate
  endif
endfunction
