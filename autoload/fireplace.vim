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
    setlocal iskeyword+=',#,%,&,/,.
    return substitute(expand('<cword>'), "^#*''*", '', '')
  finally
    let &l:iskeyword = isk
  endtry
endfunction

function! s:zipfile_url(archive, path) abort
  if get(g:, 'loaded_zipPlugin')[1:-1] > 31
    return 'zipfile://' . a:archive . '::' . a:path
  else
    return 'zipfile:' . a:archive . '::' . a:path
  endif
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

function! fireplace#EvalComplete(A, L, P, ...) abort
  let prefix = matchstr(a:A, '\%(.* \|^\)\%(#\=[\[{('']\)*')
  let keyword = strpart(a:A, strlen(prefix))
  try
    return sort(map(fireplace#omnicomplete(a:0 ? a:1() : fireplace#client(), keyword, ''), 'prefix . v:val.word'))
  catch /^Fireplace:/
    return []
  endtry
endfunction

function! fireplace#eval_complete(A, L, P) abort
  return fireplace#EvalComplete(a:A, a:L, a:P)
endfunction

function! fireplace#CljEvalComplete(A, L, P) abort
  return fireplace#EvalComplete(a:A, a:L, a:P, function('fireplace#clj'))
endfunction

function! fireplace#CljsEvalComplete(A, L, P) abort
  return fireplace#EvalComplete(a:A, a:L, a:P, function('fireplace#cljs'))
endfunction

function! fireplace#NsComplete(A, L, P) abort
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

function! fireplace#ns_complete(A, L, P) abort
  return fireplace#NsComplete(a:A, a:L, a:P)
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

function! s:complete_delegate(queue, callback, msg) abort
  call extend(a:queue, s:complete_extract(a:msg))
  if index(get(a:msg, 'status', []), 'done') !=# -1
    call a:callback(a:queue)
  endif
endfunction

function! fireplace#omnicomplete(findstart, base, ...) abort
  if a:findstart is# 1 || a:findstart is# '1'
    let line = strpart(getline('.'), 0, col('.') - 1)
    return col('.') - strlen(matchstr(line, '\k\+$')) - 1
  else
    let err = s:op_missing_error('complete', 'cider-nrepl')
    if len(err)
      throw err
    endif
    let request = {
          \ 'op': 'complete',
          \ 'symbol': a:base,
          \ 'ns': type(a:findstart) == v:t_dict ? v:null : v:true,
          \ 'extra-metadata': ['arglists', 'doc'],
          \ 'context': a:0 ? a:1 : s:get_complete_context()
          \ }
    if type(a:findstart) == v:t_func
      return fireplace#message(request, function('s:complete_delegate', [[], a:findstart]))
    elseif type(a:findstart) == v:t_dict
      return s:complete_extract(a:findstart.Message(request, v:t_dict))
    endif
    let id = fireplace#message(request, function('s:complete_add')).id
    while !fireplace#client().done(id)
      call complete_check()
      sleep 1m
    endwhile
    return []
  endif
endfunction

" Section: REPL client

function! s:NormalizeNs(client, payload) abort
  if get(a:payload, 'ns') is# v:true
    let a:payload.ns = a:client.BufferNs()
  elseif get(a:payload, 'ns') is# v:false
    let a:payload.ns = a:client.UserNs()
  elseif type(get(a:payload, 'ns', '')) == v:t_number
    let a:payload.ns = a:client.BufferNs(a:payload.ns)
  endif
  if empty(get(a:payload, 'ns', 1))
    call remove(a:payload, 'ns')
  endif
  return a:payload
endfunction

let s:clj = {}

function! s:CljBufferNs(...) dict abort
  if call('s:bufext', a:0 ? a:000 : get(self, 'args', [])) =~# '^clj[cx]\=$'
    let ns = call('fireplace#ns', a:000)
    return ns =~# '^\%(cljs\.\)\=user$' ? '' : ns
  else
    return ''
  endif
endfunction

function! s:CljExt() dict abort
  return 'clj'
endfunction

function! s:CljReplNs() dict abort
  return 'clojure.repl'
endfunction

function! s:CljUserNs() dict abort
  return 'user'
endfunction

let s:clj = {
      \ 'BufferNs': function('s:CljBufferNs'),
      \ 'Ext': function('s:CljExt'),
      \ 'ReplNs': function('s:CljReplNs'),
      \ 'UserNs': function('s:CljUserNs')}

function! s:CljsBufferNs(...) dict abort
  if call('s:bufext', a:0 ? a:000 : get(self, 'args', [])) =~# '^clj[scx]$'
    let ns = call('fireplace#ns', a:000)
    return ns =~# '^\%(cljs\.\)\=user$' ? '' : ns
  else
    return ''
  endif
endfunction

function! s:CljsExt() dict abort
  return 'cljs'
endfunction

function! s:CljsReplNs() dict abort
  return 'cljs.repl'
endfunction

function! s:CljsUserNs() dict abort
  return 'cljs.user'
endfunction

let s:cljs = {
      \ 'BufferNs': function('s:CljsBufferNs'),
      \ 'Ext': function('s:CljsExt'),
      \ 'ReplNs': function('s:CljsReplNs'),
      \ 'UserNs': function('s:CljsUserNs')}

function! s:EvalQuery(...) dict abort
  let opts = {'session': v:false}
  for l:Arg in a:000
    if type(Arg) == v:t_string
      let opts.code = Arg
    elseif type(Arg) == v:t_dict && type(get(Arg, 'Session')) ==# v:t_func
      let client = Arg
    elseif type(Arg) == v:t_dict
      call extend(opts, Arg)
    elseif type(Arg) == v:t_func
      let l:Callback = Arg
    endif
  endfor
  let opts.code = printf(g:fireplace#reader, get(opts, 'code', 'null'))
  if exists('Callback')
    return self.Eval(opts, { m -> len(get(m, 'value', '')) ? Callback(eval(m.value)) : 0 })
  endif
  let response = self.Eval(opts)
  call s:output_response(response)

  if get(response, 'ex', '') !=# ''
    let err = 'Clojure: '.response.ex
  elseif has_key(response, 'value')
    return empty(response.value) ? '' : eval(response.value[-1])
  else
    let err = 'fireplace.vim: No value in '.string(response)
  endif
  throw err
endfunction

let s:common = {'Query': function('s:EvalQuery')}

let s:repl = extend(extend({"requires": {}}, s:clj), s:common)

let s:repl.user_ns = s:repl.UserNs

if !exists('s:repls')
  let s:repls = []
  let s:repl_paths = {}
  let s:repl_portfiles = {}
endif

function! s:repl.Client() dict abort
  return self
endfunction

function! s:repl.Session() dict abort
  return self.session
endfunction

function! s:repl.Path() dict abort
  return self.transport._path
endfunction

let s:repl.path = s:repl.Path

function! s:repl.message(payload, ...) dict abort
  call s:NormalizeNs(self, a:payload)
  if has_key(a:payload, 'ns') && a:payload.ns !=# self.UserNs()
    let ignored_error = self.Preload(a:payload.ns)
  endif
  let session = self.Session()
  return call(session.message, [a:payload] + a:000, session)
endfunction

let s:repl.Message = s:repl.message

function! s:repl.done(id) dict abort
  if type(a:id) == v:t_string
    return !has_key(self.transport.requests, a:id)
  elseif type(a:id) == v:t_dict
    return index(get(a:id, 'status', []), 'done') >= 0
  else
    return -1
  endif
endfunction

let s:repl.Done = s:repl.done

function! s:repl.preload(lib) dict abort
  if !empty(a:lib) && a:lib !=# self.UserNs() && !get(self.requires, a:lib)
    let reload = has_key(self.requires, a:lib) ? ' :reload' : ''
    let self.requires[a:lib] = 0
    if self.Ext() ==# 'clj'
      let qsym = s:qsym(a:lib)
      let expr = '(clojure.core/when-not (clojure.core/find-ns '.qsym.') (try'
            \ . ' ((or (clojure.core/resolve ''clojure.core/load-one) (fn [x _ _] (clojure.core/require x))) '.qsym.' true true)'
            \ . ' (catch Exception e (clojure.core/when-not (clojure.core/find-ns '.qsym.') (throw e)))))'
    else
      let expr = '(ns '.self.UserNs().' (:require '.a:lib.reload.'))'
    endif
    let result = self.Message({'op': 'eval', 'code': expr, 'ns': self.UserNs(), 'session': ''}, v:t_dict)
    let self.requires[a:lib] = !has_key(result, 'ex')
    if has_key(result, 'ex')
      return result
    endif
  endif
  return {}
endfunction

let s:repl.Preload = s:repl.preload

function! s:repl.Eval(...) dict abort
  let options = {'op': 'eval', 'code': ''}
  for l:Arg in a:000
    if type(Arg) == v:t_string
      let options.code = Arg
    elseif type(Arg) == v:t_dict
      call extend(options, Arg)
    elseif type(Arg) == v:t_func
      let l:Callback = Arg
    endif
  endfor
  let options = s:NormalizeNs(self, options)
  if has_key(options, 'ns') && options.ns !=# self.UserNs()
    let error = self.Preload(options.ns)
    if !empty(error)
      return error
    endif
  endif
  let response = self.Message(options, exists('l:Callback') ? Callback : v:t_dict)
  if index(get(response, 'status', []), 'namespace-not-found') < 0
    return response
  endif
  throw 'Fireplace: namespace not found: ' . get(options, 'ns', '?')
endfunction

let s:repl.eval = s:repl.Eval

function! s:repl.HasOp(op) abort
  return self.transport.HasOp(a:op)
endfunction

let s:piggieback = extend(copy(s:repl), s:cljs)

let s:piggieback.user_ns = s:piggieback.UserNs

function! s:piggieback.Piggieback(arg, ...) abort
  if a:0 && a:1
    if len(self.sessions)
      let session = remove(self.sessions, 0)
      call session.Message({'op': 'eval', 'code': ':cljs/quit'}, v:t_list)
      call session.Close()
    endif
    return {}
  endif
  let session = self.clj_session.Clone()
  if empty(a:arg)
    let arg = get(self, 'default', '')
  elseif a:arg =~# '^\d\{1,5}$'
    if len(fireplace#findresource('weasel/repl/websocket.clj', self.Path()))
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
    call session.Message({'op': 'eval', 'code': "(require '" . replns . ")"}, v:t_dict)
  endif
  if arg =~# '^\S*repl-env\>' || arg !~# '('
    if len(fireplace#findresource('cemerick/piggieback.clj', self.Path())) && !len(fireplace#findresource('cider/piggieback.clj', self.Path()))
      let arg = '(cemerick.piggieback/cljs-repl ' . arg . ')'
    else
      let arg = '(cider.piggieback/cljs-repl ' . arg . ')'
    endif
  endif
  let response = session.Message({'op': 'eval', 'code': arg}, v:t_dict)
  if !has_key(response, 'ex') && get(response, 'ns', 'user') ==# 'cljs.user'
    call insert(self.sessions, session)
  else
    call session.Close()
  endif
  return response
endfunction

function! s:piggieback.Session() abort
  if len(self.sessions)
    return self.sessions[0]
  endif
  let response = self.Piggieback('')
  if len(self.sessions)
    return self.sessions[0]
  endif
  call s:output_response(response)
  throw 'Fireplace: error starting ClojureScript REPL'
endfunction

function! s:register(session, ...) abort
  call insert(s:repls, extend({'session': a:session, 'transport': a:session.transport, 'cljs_sessions': []}, deepcopy(s:repl)))
  if a:0 && a:1 !=# ''
    let s:repl_paths[a:1] = s:repls[0]
  endif
  return s:repls[0]
endfunction

function! s:unregister(transport) abort
  let transport = get(a:transport, 'transport', a:transport)
  let criteria = 'has_key(v:val, "transport") && v:val.transport isnot# transport'
  call filter(s:repl_paths, criteria)
  call filter(s:repls, criteria)
  call filter(s:repl_portfiles, criteria)
endfunction

function! s:unregister_dead() abort
  let criteria = 'has_key(v:val, "transport") && v:val.transport.Alive()'
  call filter(s:repl_paths, criteria)
  call filter(s:repls, criteria)
  call filter(s:repl_portfiles, criteria)
endfunction

function! fireplace#register_port_file(portfile, ...) abort
  let portfile = fnamemodify(a:portfile, ':p')
  let old = get(s:repl_portfiles, portfile, {})
  if has_key(old, 'time') && getftime(portfile) !=# old.time
    call s:unregister(old)
    let old = {}
  endif
  if empty(old) && getfsize(portfile) > 0
    let port = matchstr(readfile(portfile, 'b', 1)[0], '\d\+')
    try
      let transport = fireplace#transport#connect(port)
      let session = transport.Clone()
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

function! fireplace#ConnectComplete(A, L, P) abort
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

function! fireplace#ConnectCommand(line1, line2, range, bang, mods, arg, args) abort
  let str = get(a:args, 0, '')
  if empty(str)
    let str = input('Port or URL: ')
    if empty(str)
      return ''
    endif
  endif
  let str = substitute(str, '^file:[\/]\{' . (has('win32') ? '3' : '2') . '\}', '', '')
  if str =~# '^[%#]'
    let str = expand(str)
  endif
  if str !~# '^\d\+$\|:\d\|:[\/][\/]' && filereadable(str)
    let path = fnamemodify(str, ':p:h')
    let str = readfile(str, '', 1)[0]
  elseif str !~# '^\d\+$\|:\d\|:[\/][\/]' && filereadable(str . '/.nrepl-port')
    let path = fnamemodify(str, ':p:h')
    let str = readfile(str . '/.nrepl-port', '', 1)[0]
  else
    let path = fnamemodify(exists('b:java_root') ? b:java_root : getcwd(), ':~')
  endif
  try
    let transport = fireplace#transport#connect(str)
  catch /.*/
    return 'echoerr '.string(v:exception)
  endtry
  if type(transport) !=# type({}) || empty(transport)
    return ''
  endif
  let client = s:register(transport.Clone())
  echo 'Connected to ' . transport.url
  let root = len(a:args) > 1 ? expand(a:args[1]) : input('Scope connection to: ', path, 'dir')
  if root !=# '' && root !=# '-'
    let s:repl_paths[fnamemodify(root, ':p:s?.\zs[\/]$??')] = client
  endif
  return ''
endfunction

function! s:piggieback(count, arg, remove) abort
  try
    let response = s:Cljs().Piggieback(a:arg, a:remove)
    call s:output_response(response)
    return ''
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

function! s:set_up_connect() abort
  command! -buffer -bang -bar -complete=customlist,fireplace#ConnectComplete -nargs=*
        \ Connect FireplaceConnect<bang> <args>
  command! -buffer -bang -range=-1 -complete=customlist,fireplace#eval_complete -nargs=*
        \ Piggieback exe s:piggieback(<count>, <q-args>, <bang>0)
endfunction

" Section: Java runner

if !exists('s:spawns')
  let s:spawns = {}
endif

function! s:spawn_interrupt(id) abort
  let message = get(s:spawns, a:id, {})
  if type(get(message, 'job', '')) == v:t_number
    call jobstop(message.job)
  elseif type(get(message, 'job', '')) != v:t_string
    call job_stop(message.job)
  endif
endfunction

function! s:spawn_wait(id, ...) abort
  let message = get(s:spawns, a:id, {})
  let finished = v:true
  if type(get(message, 'job', '')) == v:t_number
    let finished = jobwait([message.job], a:0 ? a:1 : -1)[0] == -1 ? v:false : v:true
  elseif type(get(message, 'job', '')) != v:t_string
    let ms = 0
    let max = a:0 ? a:1 : -1
    while job_status(message.job) ==# 'run'
      if ms == max
        let finished = v:false
        break
      endif
      let ms += 1
      sleep 1m
    endwhile
  endif
  if has_key(s:spawns, a:id)
    throw 'Fireplace: race condition waiting on spawning eval?'
  endif
  return finished
endfunction

function! s:spawn_complete(id, name, callback) abort
  let result = {'id': a:id}
  let result.value = join(readfile(a:name . '.pr' , 'b'), "\n")
  let result.out   = join(readfile(a:name . '.out', 'b'), "\n")
  let result.err   = join(readfile(a:name . '.err', 'b'), "\n")
  let result.ex    = join(readfile(a:name . '.ex' , 'b'), "\n")
  if empty(result.ex)
    let result.status = ['done']
  else
    let result.status = ['eval-error', 'done']
  endif
  call filter(result, '!empty(v:val)')
  call remove(s:spawns, a:id)
  try
    call a:callback(result)
  catch
  endtry
endfunction

function! s:spawn_eval(id, classpath, expr, ns, callback) abort
  if a:ns !=# '' && a:ns !=# 'user'
    let ns = '(require '.s:qsym(a:ns).') (in-ns '.s:qsym(a:ns).') '
  else
    let ns = ''
  endif
  let tempname = tempname()
  call writefile([], tempname . '.pr', 'b')
  call writefile([], tempname . '.ex', 'b')
  call writefile(split('(do '.a:expr.')', "\n"), tempname . '.in', 'b')
  call writefile([], tempname . '.out', 'b')
  call writefile([], tempname . '.err', 'b')
  let java_cmd = split(exists('$JAVA_CMD') ? $JAVA_CMD : 'java', ' ')
  let command = java_cmd + ['-cp', a:classpath, 'clojure.main', '-e',
        \   '  (try' .
        \   '    (require ''clojure.repl ''clojure.java.javadoc) '. ns .
        \   '    (spit '.s:str(tempname . '.pr').' (pr-str (eval (read-string (slurp '.s:str(tempname . '.in').')))))' .
        \   '    (catch Exception e' .
        \   '      (spit *err* (.toString e))' .
        \   '      (spit '.s:str(tempname . '.ex').' (class e))))']
  let s:spawns[a:id] = {}
  if has('job')
    let opts = {
          \ 'out_io': 'file', 'out_name': tempname . '.out',
          \ 'err_io': 'file', 'err_name': tempname . '.err',
          \ 'exit_cb': { j, data -> s:spawn_complete(a:id, tempname, a:callback) }}
    let s:spawns[a:id].job = job_start(command, opts)
  elseif exists('*jobstart')
    let opts = {
          \ 'on_stdout': { j, data, type -> writefile(data, tempname . '.out', 'ab') },
          \ 'on_stderr': { j, data, type -> writefile(data, tempname . '.err', 'ab') },
          \ 'on_exit': { j, data, type -> s:spawn_complete(a:id, tempname, a:callback) }}
    let s:spawns[a:id].job = jobstart(command, opts)
  endif
  return {'id': a:id}
endfunction

let s:no_repl = 'Fireplace: no live REPL connection'

let s:oneoff = extend(copy(s:clj), s:common)

let s:oneoff.user_ns = s:repl.UserNs

function! s:oneoff.Client() dict abort
  return self
endfunction

function! s:oneoff.Path() dict abort
  return self._path
endfunction

let s:oneoff.path = s:oneoff.Path

function! s:oneoff.Eval(...) dict abort
  let options = {'op': 'eval', 'code': ''}
  for l:Arg in a:000
    if type(Arg) == v:t_string
      let options.code = Arg
    elseif type(Arg) == v:t_dict
      call extend(options, Arg)
    elseif type(Arg) == v:t_func
      let l:Callback = Arg
    endif
  endfor
  if !empty(get(options, 'session', 1))
    throw s:no_repl
  endif
  let id = has_key(options, 'id') ? options.id : fireplace#transport#id()
  let path = join(self.Path(), has('win32') ? ';' : ':')
  let options = s:NormalizeNs(self, options)
  let ns = get(options, 'ns', self.UserNs())
  let queue = []
  if exists('l:Callback')
    return s:spawn_eval(id, path, options.code, ns, l:Callback)
  endif
  call s:spawn_eval(id, path, options.code, ns, function('add', [queue]))
  call s:spawn_wait(id)
  return fireplace#transport#combine(queue)
endfunction

let s:oneoff.eval = s:oneoff.Eval

function! s:oneoff.Session(...) abort
  throw s:no_repl
endfunction

function! s:oneoff.HasOp(op) abort
  return 0
endfunction

let s:oneoff.message = s:oneoff.Session
let s:oneoff.Message = s:oneoff.Session

" Section: Client

function! s:buffer_absolute(...) abort
  let buffer = call('s:buf', a:000)
  let path = substitute(fnamemodify(bufname(buffer), ':p'), '\C^zipfile:\%([\/][\/]\)\=\(.*\)::', '\1/', '')
  let scheme = substitute(matchstr(path, '^\a\a\+\ze:'), '^.', '\u&', '')
  if len(scheme) && exists('*' . scheme . 'Real')
    let path = {scheme}Real(path)
  elseif getbufvar(buffer, '&buftype') !~# '^$\|^acwrite$'
    return ''
  endif
  if path !~# '^/\|^\a\+:\|^$' && isdirectory(matchstr(path, '^[^\/]\+[\/]'))
    let path = getcwd() . matchstr(path, '[\/]') . path
  endif
  return path =~# '^\a:[\/]\|^/' ? simplify(path) : ''
endfunction

function! s:buffer_path(...) abort
  let buffer = call('s:buf', a:000)
  let path = s:buffer_absolute(buffer)
  for dir in fireplace#path(buffer)
    if dir !=# '' && path[0 : strlen(dir)-1] ==# dir && path[strlen(dir)] =~# '[\/]'
      return path[strlen(dir)+1:-1]
    endif
  endfor
  return ''
endfunction

function! fireplace#ns(...) abort
  let buffer = call('s:buf', a:000)
  if !empty(getbufvar(buffer, 'fireplace_ns'))
    return getbufvar(buffer, 'fireplace_ns')
  endif
  let head = getbufline(buffer, 1, 500)
  let blank = '^\s*\%(\%(;\|#!\).*\)\=$'
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

function! s:buf(...) abort
  if exists('s:input') && !a:0
    return s:input
  endif
  let bufnr = a:0 && a:1 >= 0 && a:1 isnot# v:true ? a:1 : bufnr('')
  let fullname = fnamemodify(bufname(bufnr), ':p')
  if has_key(s:qffiles, fullname)
    return s:qffiles[fullname].buffer
  else
    return bufnr
  endif
endfunction

function! s:bufext(...) abort
  return matchstr(bufname(call('s:buf', a:000)), '\.\zs\w\+$')
endfunction

function! s:impl_ns(...) abort
  let buf = a:0 ? a:1 : s:buf()
  let ext = fnamemodify(bufname(buf), ':e')
  if ext ==# 'cljs'
    return 'cljs'
  elseif ext ==# 'clj'
    return 'clojure'
  elseif !empty(get(b:, 'fireplace_cljc_platform', ''))
    return b:fireplace_cljc_platform is# 'cljs' ? 'cljs' : 'clj'
  else
    try
      if len(get(call('fireplace#native', a:000), 'cljs_sessions', []))
        return 'cljs'
      endif
    catch /^Fireplace: no live REPL connection/
    endtry
    return 'clojure'
  endif
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
  for path in a:path
    if len(path) && strpart(a:file, 0, len(path)) ==? path
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
  let absolute = s:buffer_absolute(buf)
  for repl in s:repls
    if s:includes_file(absolute, repl.Path())
      return repl.Path()
    endif
  endfor
  return s:path_extract(getbufvar(buf, '&path'))
endfunction

function! fireplace#native(...) abort
  call s:unregister_dead()
  for [k, v] in items(s:repl_portfiles)
    if getftime(k) != v.time
      call s:unregister(v)
    endif
  endfor

  let buf = a:0 ? a:1 : s:buf()
  let path = s:buffer_absolute(buf)

  let portfile = findfile('.nrepl-port', (a:0 ? fnamemodify(path, ':h') : '.') . ';')
  if !empty(portfile) && filereadable(portfile)
    call fireplace#register_port_file(portfile, fnamemodify(portfile, ':p:h'))
  else
    let portfile = findfile('.shadow-cljs/nrepl.port', (a:0 ? fnamemodify(path, ':h') : '') . ';')
    if !empty(portfile) && filereadable(portfile)
      call fireplace#register_port_file(portfile, fnamemodify(portfile, ':p:h:h'))
    endif
  endif

  if !a:0
    silent doautocmd <nomodeline> User FireplacePreConnect
  endif

  let root = substitute(path, '[\/]$', '', '')
  let previous = ""
  while root !=# previous
    if has_key(s:repl_paths, root)
      return s:repl_paths[root]
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile
  for repl in s:repls
    if s:includes_file(path, repl.Path())
      return repl
    endif
  endfor
  let path = s:path_extract(getbufvar(buf, '&path'))
  if !empty(path)
    return extend({'_path': path, 'nr': bufnr(buf)}, s:oneoff)
  endif
  throw s:no_repl
endfunction

function! s:PlatformDelegate(func, ...) dict abort
  if self.Ext() ==# 'cljs'
    let fn = 's:Cljs'
  else
    let fn = 'fireplace#native'
  endif
  let obj = call(fn, get(self, 'args', []))
  return call(obj[a:func], a:000, obj)
endfunction

function! s:NativeDelegate(func, ...) dict abort
  let obj = call('fireplace#native', get(self, 'args', []))
  return call(obj[a:func], a:000, obj)
endfunction

let s:delegate = {
      \ 'Client': function('s:PlatformDelegate', ['Client']),
      \ 'Eval': function('s:PlatformDelegate', ['Eval']),
      \ 'HasOp': function('s:NativeDelegate', ['HasOp']),
      \ 'Query': function('s:PlatformDelegate', ['Query']),
      \ 'Message': function('s:PlatformDelegate', ['Message']),
      \ 'Path': function('s:NativeDelegate', ['Path']),
      \ 'Session': function('s:PlatformDelegate', ['Session']),
      \ }

let s:clj_delegate = extend(copy(s:clj), s:delegate)
let s:cljs_delegate = extend(copy(s:cljs), s:delegate)

function! fireplace#clj(...) abort
  return extend({'args': a:000}, s:clj_delegate)
endfunction

function! fireplace#cljs(...) abort
  return extend({'args': a:000}, s:cljs_delegate)
endfunction

function! fireplace#platform(...) abort
  if call('s:impl_ns', a:000) ==# 'cljs'
    return call('fireplace#cljs', a:000)
  else
    return call('fireplace#clj', a:000)
  endif
endfunction

function! s:Cljs(...) abort
  let client = call('fireplace#native', a:000)
  if !has_key(client, 'cljs_sessions')
    throw s:no_repl
  endif
  let buf = bufnr(a:0 ? a:1 : s:buf())
  let default = getbufvar(buf, 'fireplace_cljs_repl', get(g:, 'fireplace_cljs_repl', ''))
  let cljs = extend({'default': default, 'transport': client.transport, 'sessions': client.cljs_sessions, 'clj_session': client.session}, s:piggieback)
  return cljs
endfunction

function! fireplace#client(...) abort
  let buf = a:0 ? a:1 : s:buf()
  let ext = fnamemodify(bufname(buf), ':e')
  if ext ==# 'cljs'
    return call('s:Cljs', a:000)
  endif
  let client = call('fireplace#native', a:000)
  if ext !=# 'clj' && len(get(client, 'cljs_sessions', []))
    return call('s:Cljs', a:000)
  endif
  return client
endfunction

function! fireplace#message(payload, ...) abort
  let client = fireplace#client()
  let payload = copy(a:payload)
  if !has_key(payload, 'ns')
    let payload.ns = v:true
  endif
  return call(client.Message, [payload] + a:000, client)
endfunction

function! fireplace#interrupt(msg_or_id) abort
  let id = type(a:msg_or_id) ==# v:t_dict ? get(a:msg_or_id, 'id', '') : a:msg_or_id
  call s:spawn_interrupt(id)
  call fireplace#transport#interrupt(id)
  return a:msg_or_id
endfunction

function! fireplace#wait(msg_or_id_or_list, ...) abort
  if type(a:msg_or_id_or_list) != v:t_list
    return call('fireplace#wait', [[a:msg_or_id_or_list]] + a:000)[0]
  endif
  try
    let results = []
    for item in a:msg_or_id_or_list
      let id = type(item) ==# v:t_dict ? get(item, 'id', '') : item
      call add(results, (call('s:spawn_wait', [id] + a:000) &&
            \ call('fireplace#transport#wait', [id] + a:000)) ? v:true : v:false)
    endfor
    let finished = 1
    return results
  finally
    if !a:0 && !exists('finished')
      for item in a:msg_or_id_or_list
        call fireplace#interrupt(item)
      endfor
    endif
  endtry
endfunction

function! fireplace#id() abort
  return fireplace#transport#id()
endfunction

function! s:op_missing_error(op, ...) abort
  try
    let client = fireplace#native()
    if !has_key(client, 'transport')
      return s:no_repl
    elseif client.transport.HasOp(a:op)
      return ''
    elseif a:0
      return 'Fireplace: no ' . string(a:op) . ' nREPL op available (is ' . a:1 . ' installed?)'
    else
      return 'Fireplace: no ' . string(a:op) . ' nREPL op available'
    endif
  catch /^Fireplace: no live REPL connection/
    return s:no_repl
  endtry
endfunction

function! s:op_guard(...) abort
  let err = call('s:op_missing_error', a:000)
  if empty(err)
    return ''
  endif
  return 'return ' . string('echoerr ' . string(err))
endfunction

function! fireplace#op_available(op) abort
  return empty(s:op_missing_error(a:op))
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
        return s:zipfile_url(dir, resource . suffix)
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

function! s:qfhistory_item(entry) abort
  if !has_key(a:entry, 'tempfile')
    let a:entry.tempfile = s:temp_response(a:entry.response, get(a:entry, 'ext', 'clj'))
  endif
  let s:qffiles[a:entry.tempfile] = a:entry
  return {'filename': a:entry.tempfile, 'text': a:entry.code, 'type': 'E', 'module': a:entry.response.id}
endfunction

function! s:qfhistory() abort
  let list = []
  for entry in reverse(copy(s:history))
    call extend(list, [s:qfhistory_item(entry)])
  endfor
  return list
endfunction

function! s:echon(state, str, hlgroup) abort
  let str = get(a:state, 'echo_buffer', '') . a:str
  let a:state.echo_buffer = matchstr(str, "\n$")
  if get(a:state, 'echo', v:true)
    exe 'echohl' a:hlgroup
    echon len(a:state.echo_buffer) ? str[0:-2] : str
    echohl NONE
  endif
endfunction

function! s:eval_callback(state, delegates, message) abort
  call add(a:state.history.messages, a:message)
  if has_key(a:message, 'ex')
    let a:state.ex = a:message.ex
  endif
  if has_key(a:message, 'ns')
    let a:state.ns = a:message.ns
  endif
  if has_key(a:message, 'out')
    call s:echon(a:state, a:message.out, 'Question')
  endif
  if has_key(a:message, 'err')
    call s:echon(a:state, a:message.err, 'WarningMsg')
  endif
  if has_key(a:message, 'value')
    call s:echon(a:state, a:message.value, 'NONE')
    if has_key(a:message, 'ns')
      call s:echon(a:state, "\n", 'NONE')
    endif
  endif

  for Delegate in a:delegates
    try
      call call(Delegate, [a:message])
    catch
    endtry
  endfor
  if index(get(a:message, 'status', []), 'done') >= 0
    if has_key(a:state, 'client')
      let client = a:state.client
      if len(get(client, 'sessions', [])) && a:state.code =~# '^\s*:cljs/quit\s*$' && !has_key(state, 'ex')
        let old_session = remove(client.sessions, 0)
        call old_session.Close()
      elseif has_key(client, 'cljs_sessions') && get(a:state, 'ns', '') ==# 'cljs.user'
        call insert(client.cljs_sessions, client.Session().Clone())
        call client.Message({'op': 'eval', 'code': ':cljs/quit'}, v:t_dict)
      endif
    endif
    let a:state.history.response = fireplace#transport#combine(a:state.history.messages)
    let response = a:state.history.response
    let buffer = []
    for [prefix, value] in [[';!', get(response, 'err', '')], [';=', get(response, 'out', '')]] +
          \ map(copy(get(response, 'value', [])), { _, v -> ['', v]})
      let lines = split(value, "\n", 1)
      if empty(lines[-1])
        call remove(lines, -1)
      endif
      let buffer += map(lines, 'prefix . v:val')
    endfor
    call add(buffer, '')
    call writefile(buffer, a:state.history.tempfile, 'b')
    call insert(s:history, a:state.history)
    if len(s:history) > &history
      call remove(s:history, &history, -1)
    endif
    if get(a:state, 'bg')
      exe s:Last(1, 1)
    endif
    if a:state.history.buffer == bufnr('')
      try
        silent doautocmd User FireplaceEvalPost
      catch
      endtry
    endif
  endif
endfunction

function! fireplace#eval(...) abort
  let opts = {}
  let state = {'echo': v:false}
  let callbacks = []
  for l:Arg in a:000
    if type(Arg) == v:t_string
      let opts.code = Arg
    elseif type(Arg) == v:t_dict && type(get(Arg, 'Session')) ==# v:t_func
      let platform = Arg
    elseif type(Arg) == v:t_dict
      call extend(opts, Arg)
    elseif type(Arg) == v:t_func
      call add(callbacks, Arg)
    elseif type(Arg) == v:t_bool
      let state.echo = Arg
    elseif type(Arg) == v:t_number
      call s:add_pprint_opts(opts, Arg)
    endif
  endfor
  let code = remove(opts, 'code')

  let native = fireplace#native()
  let ext = matchstr(bufname(s:buf()), '\.\zs\w\+$')
  if !exists('platform') && !has_key(opts, 'session') && has_key(native, 'cljs_sessions') && ext =~# '^clj[csx]$' && code =~# '^\s*(\S\+/cljs-repl'
    let platform = native
  elseif !exists('platform')
    let platform = fireplace#platform()
  endif
  if !has_key(opts, 'ns')
    let opts.ns = v:true
  endif
  let ext = platform.Ext()

  let client = platform.Client()
  let state.code = code
  let state.history = {'buffer': bufnr(''), 'tempfile': tempname() . '.' . ext, 'ext': ext, 'code': code, 'ns': fireplace#ns(), 'messages': []}
  if !has_key(opts, 'session')
    let state.client = client
  endif
  let msg = client.Eval(code, opts, function('s:eval_callback', [state, callbacks]))

  if state.echo
    echo ""
  endif

  if len(callbacks)
    return msg
  endif

  try
    while !fireplace#wait(msg.id, 1)
      let peek = getchar(1)
      if state.echo && peek != 0 && !(has('win32') && peek == 128)
        let c = getchar()
        let c = type(c) == type(0) ? nr2char(c) : c
        if c ==# "\<C-D>"
          let state.echo = v:false
          let state.bg = v:true
          echo "\rBackgrounded"
          let finished = 1
          return []
        else
          call fireplace#transport#stdin(msg.id, c)
          echon c
        endif
      endif
    endwhile
    let finished = 1
  finally
    if !exists('l:finished')
      call fireplace#interrupt(msg.id)
    endif
  endtry

  if get(state, 'ex', '') !=# ''
    let err = 'Clojure: '.state.ex
  else
    return get(state.history.response, 'value', [])
  endif
  throw err
endfunction

function! fireplace#session_eval(...) abort
  return get(call('fireplace#eval', a:000), -1, '')
endfunction

function! s:DisplayWidth() abort
  if exists('g:fireplace_display_width') && g:fireplace_display_width < &columns
    return g:fireplace_display_width
  else
    return &columns
  endif
endfunction

function! s:RefreshLast() abort
  for win in range(1, winnr('$'))
    if getwinvar(win, '&previewwindow')
      let loclist = getloclist(win)
      if len(loclist) && map(loclist, 'v:val.text') == map(s:qfhistory()[0 : len(loclist)-1], 'v:val.text')
        exe s:Last(1, 1)
      endif
    endif
  endfor
endfunction

function! fireplace#echo_session_eval(...) abort
  try
    call call('fireplace#eval', [s:DisplayWidth(), v:true] + a:000)
    call s:RefreshLast()
  catch
    if v:exception =~# '^Clojure:'
      call s:RefreshLast()
    endif
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
      \    ' (true? x)    "v:true"' .
      \    ' (false? x)   "v:false"' .
      \    ' (nil? x)     "v:null"' .
      \    ' (number? x)  (pr-str x)' .
      \    ' (keyword? x) (pr-str (name x))' .
      \    ' :else        (pr-str (str x)))) %s))'

function! fireplace#query(...) abort
  let args = [{'ns': v:true}]
  let client = fireplace#platform()
  for l:Arg in a:000
    if type(Arg) == v:t_dict && type(get(Arg, 'Session')) ==# v:t_func
      let client = Arg
    else
      call add(args, Arg)
    endif
  endfor
  return call(client.Query, args, client)
endfunction

function! fireplace#evalparse(expr, ...) abort
  return fireplace#query(a:expr, a:0 ? a:1 : {})
endfunction

" Section: Quickfix

function! s:qfmassage(line, path) abort
  let item = {'text': a:line}
  let match = matchlist(a:line, '^\s*\(\S\+\)\s\=(\([^:()[:space:]]*\)\%(:\(\d\+\)\)\=)$')
  if !empty(match)
    let [_, class, file, lnum; __] = match
    let item.module = class
    let item.lnum = +lnum
    if file ==# 'NO_SOURCE_FILE' || !lnum
      let item.resource = ''
    else
      let truncated = substitute(class, '\.[A-Za-z0-9_]\+\%([$/].*\)$', '', '')
      let item.resource = tr(truncated, '.', '/') . '/' . file
    endif
    let item.filename = fireplace#findresource(item.resource, a:path)
    if has('patch-8.0.1782')
      let item.text = ''
    else
      let item.text = class
    endif
  endif
  return item
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
    let l:GetList = function('getloclist', [a:1])
    let l:SetList = function('setloclist', [a:1])
  else
    let l:GetList = function('getqflist', [])
    let l:SetList = function('setqflist', [])
  endif
  let path = p =~# '^[:;]' ? split(p[1:-1], p[0]) : p[0] ==# ',' ? s:path_extract(p[1:-1], 1) : s:path_extract(p, 1)
  let qflist = l:GetList()
  for item in qflist
    if !item.bufnr && !entry.lnum
      call extend(item, s:qfmassage(get(item, 'text', ''), path))
    endif
  endfor
  let attrs = l:GetList({'title': 1})
  call l:SetList(qflist, 'r')
  call l:SetList([], 'r', attrs)
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

function! s:Eval(type, line1, line2, range, bang, mods, args) abort
  let options = {}
  if a:args !=# ''
    let expr = a:args
  else
    if a:line2 < 0
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
  try
    let args = (a:type ==# 'platform' || a:type ==# 'client' ? [{'ns': v:true}] : [fireplace#{a:type}(), {'ns': v:null}]) + [expr, options]
    if a:bang
      let result = split(join(map(call('fireplace#eval', [&textwidth] + args), 'substitute(v:val, "\n*$", "", "")'), "\n"), "\n")
      if a:args !=# ''
        call append(a:line1, result)
        exe a:line1
      else
        call append(a:line1-1, result)
        exe a:line1-1
      endif
    else
      call call('fireplace#echo_session_eval', args)
    endif
  catch /^Clojure:/
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
  return ''
endfunction

function! fireplace#CljEvalCommand(line1, line2, range, bang, mods, args) abort
  return s:Eval('clj', a:line1, a:line2, a:range, a:bang, a:mods, a:args)
endfunction

function! fireplace#CljsEvalCommand(line1, line2, range, bang, mods, args) abort
  return s:Eval('cljs', a:line1, a:line2, a:range, a:bang, a:mods, a:args)
endfunction

function! s:stacktrace_list(all) abort
  let response = fireplace#message({'op': 'stacktrace'}, v:t_dict)
  if !has_key(response, 'stacktrace')
    throw 'Fireplace: no error available'
  endif
  let path = fireplace#path()
  let qf = {
        \ 'title': response.class . ': ' . response.message,
        \ 'context': {'fireplace': response},
        \ 'items': []}
  for entry in response.stacktrace
    let flags = get(entry, 'flags', [])
    if !a:all && (index(flags, 'dup') != -1 || index(flags, 'repl') != -1 || index(flags, 'tooling') != -1)
      continue
    endif
    let item = {
          \ 'module': get(entry, 'var', entry.name),
          \ 'lnum': get(entry, 'line'),
          \ }
    if get(entry, 'file', '') =~# '^\%(NO_SOURCE_FILE\)\=$' || !item.lnum || !has_key(entry, 'class')
      let item.resource = ''
    else
      let item.resource = tr(entry.class, '.', '/') . '/' . entry.file
    endif
    let item.filename = fireplace#findresource(item.resource, path)
    if empty(item.filename) && !empty(get(entry, 'file-url', ''))
      let item.filename = substitute(substitute(entry['file-url'],
            \ '^jar:file:\([^!]*\)!/', '\=s:zipfile_url(submatch(1), "")', ''),
            \ '^file:', '', '')
    endif
    if has('patch-8.0.1782')
      let item.text = join(flags, ' ')
    else
      let item.text = item.module
    endif
    if index(flags, 'dup') == -1
      call add(qf.items, item)
    endif
  endfor
  return qf
endfunction

function! s:StacktraceCommand(bang, args) abort
  exe s:op_guard('stacktrace', 'cider-nrepl')
  try
    let list = s:stacktrace_list(a:bang)
    call setqflist(remove(list, 'items'))
    call setqflist([], 'a', list)
    return 'copen'
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
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
  command! -buffer -bang -range -nargs=? -complete=customlist,fireplace#eval_complete Eval :exe s:Eval('platform', <line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>)
  command! -buffer -bang -bar -count=1 Last exe s:Last(<bang>0, <count>)
  command! -buffer -bang -bar -nargs=* Stacktrace exe s:StacktraceCommand(<bang>0, [<f-args>])

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

function! s:Require(bang, ns) abort
  if &autowrite || &autowriteall
    silent! wall
  endif
  if s:impl_ns() ==# 'cljs'
    let cmd = '(ns cljs.user (:require '.(a:ns ==# '' ? fireplace#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').'))'
  else
    let cmd = '(' . s:impl_ns() . '.core/require '.s:qsym(a:ns ==# '' ? fireplace#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').')'
  endif
  try
    call fireplace#echo_session_eval(cmd, {'ns': s:user_ns()})
    return ''
  catch /^Clojure:.*/
    return ''
  catch /^Fireplace:.*/
    return 'echoerr ' . string(v:exception)
  endtry
endfunction

function! s:set_up_require() abort
  command! -buffer -bar -bang -complete=customlist,fireplace#ns_complete -nargs=? Require :exe s:Require(<bang>0, <q-args>)

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
        \ '(clojure.core/cond'
        \ . '(clojure.core/not (clojure.core/symbol? ' . sym . '))'
        \ . '{}'
        \ . '(clojure.core/special-symbol? ' . sym . ')'
        \ . "(clojure.core/if-let [m (#'clojure.repl/special-doc " . sym . ")]"
        \ .   ' {:name (:name m)'
        \ .    ' :special-form "true"'
        \ .    ' :doc (:doc m)'
        \ .    ' :url (:url m)'
        \ .    ' :forms-str (clojure.core/str "  " (:forms m))}'
        \ .   ' {})'
        \ . '(clojure.core/find-ns ' . sym . ')'
        \ . "(clojure.core/if-let [m (#'clojure.repl/namespace-doc (clojure.core/find-ns " . sym . "))]"
        \ .   ' {:ns (:name m)'
        \ .   '  :doc (:doc m)}'
        \ .   ' {})'
        \ . ':else'
        \ . '(clojure.core/if-let [m (clojure.core/meta (clojure.core/resolve ' . sym .'))]'
        \ .   ' {:name (:name m)'
        \ .    ' :ns (:ns m)'
        \ .    ' :macro (clojure.core/when (:macro m) true)'
        \ .    ' :resource (:file m)'
        \ .    ' :line (:line m)'
        \ .    ' :doc (:doc m)'
        \ .    ' :arglists-str (clojure.core/str (:arglists m))}'
        \ .   ' {})'
        \ . ' )'
  return fireplace#query(cmd)
endfunction

function! fireplace#source(symbol) abort
  let info = fireplace#info(a:symbol)

  let file = ''
  if !empty(get(info, 'resource'))
    let file = fireplace#findresource(info.resource)
  endif

  if empty(file)
    if get(info, 'file', '') =~# '^file:'
      let file = substitute(strpart(info.file, 5), '/', s:slash(), 'g')
    elseif get(info, 'file', '') =~# '^jar:file:'
      let zip = matchstr(info.file, '^jar:file:\zs.*\ze!')
      let file = s:zipfile_url(zip, info.resource)
    else
      let file = get(info, 'file', '')
    endif
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

if !exists('s:tag_file')
  let s:tag_file = tempname() . '.fireplace.tags'
endif

function! s:Tag(cmd, keyword) abort
  try
    let location = fireplace#source(a:keyword)
  catch /^Clojure:/
    return ''
  endtry
  let after = ''
  let tag_contents = [
        \ "!_TAG_FILE_FORMAT\t2\t/extended format; --format=1 will not append ;\" to lines/",
        \ "!_TAG_FILE_SORTED\t1\t/0=unsorted, 1=sorted, 2=foldcase/",
        \ "!_TAG_PROGRAM_NAME\tfireplace.vim\t//"]
  if len(location)
    let line = matchstr(location, '^+\zs\d\+')
    let file = expand(matchstr(location, ' \zs.*'))
    if file =~# '^zipfile:.*::'
      let after = '|keepalt keepjumps edit +' . line . ' ' . fnameescape(file)
      let line = 1
      let file = matchstr(file, 'zipfile:\%([\/][\/]\)\=\zs.\{-\}\ze::')
    endif
    call add(tag_contents, a:keyword . "\t" . file . "\t" . line . ";\"\tlanguage:Clojure")
  endif
  call writefile(tag_contents, s:tag_file)
  let old_tags = &l:tags
  let &l:tags = escape(s:tag_file, ' ,')
  return a:cmd . ' ' . a:keyword . '|call setbufvar(' . bufnr('') . ', "&tags", ' . string(old_tags). ')' . after
endfunction

nnoremap <silent> <Plug>FireplaceTag :<C-U>exe <SID>Tag('tag', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceTjump :<C-U>exe <SID>Tag('tjump', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceTselect :<C-U>exe <SID>Tag('tselect', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceStag :<C-U>exe <SID>Tag('stag', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceStjump :<C-U>exe <SID>Tag('stjump', <SID>cword())<CR>
nnoremap <silent> <Plug>FireplaceStselect :<C-U>exe <SID>Tag('stselect', <SID>cword())<CR>

function! s:set_up_source() abort
  setlocal define=^\\s*(def\\w*
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Djump  :exe s:Edit('edit', <q-args>)
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Dsplit :exe s:Edit('<mods> split', <q-args>)

  call s:map('n', '[<C-D>',     '<Plug>FireplaceDjump')
  call s:map('n', ']<C-D>',     '<Plug>FireplaceDjump')
  call s:map('n', '<C-W><C-D>', '<Plug>FireplaceDsplit')
  call s:map('n', '<C-W>d',     '<Plug>FireplaceDsplit')
  call s:map('n', '<C-W>gd',    '<Plug>FireplaceDtabjump')

  call s:map('n', '<C-]>',         '<Plug>FireplaceTag')
  call s:map('n', 'g<LeftMouse>',  '<Plug>FireplaceTag')
  call s:map('n', '<C LeftMouse>', '<Plug>FireplaceTag')
  call s:map('n', 'g]',            '<Plug>FireplaceTselect')
  call s:map('n', 'g<C-]>',        '<Plug>FireplaceTjump')
  call s:map('n', '<C-W>]',        '<Plug>FireplaceStag')
  call s:map('n', '<C-W><C-]>',    '<Plug>FireplaceStag')
  call s:map('n', '<C-W>g]',       '<Plug>FireplaceStselect')
  call s:map('n', '<C-W>g<C-]>',   '<Plug>FireplaceStjump')
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
    set isfname+=',*
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
  exe s:op_guard(op, 'cider-nrepl')
  try
    let symbol = fireplace#qualify_keyword(a:kw)
    let response = fireplace#message({'op': op, 'spec-name': symbol}, v:t_dict)
    if !empty(get(response, op))
      echo s:pr(get(response, op))
    endif
  catch /^Fireplace:/
    return 'echoerr ' . string(v:exception)
  endtry
  return ''
endfunction

function! s:SpecExample(kw) abort
  let op = "spec-example"
  exe s:op_guard(op, 'cider-nrepl')
  try
    let symbol = fireplace#qualify_keyword(a:kw)
    let response = fireplace#message({'op': op, 'spec-name': symbol}, v:t_dict)
    echo get(response, op, '')
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
    let response = fireplace#client().Eval('('.a:ns.'/'.a:macro.' '.a:arg.')', {'session': '', 'ns': v:true})
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
  if s:repl_ns() ==# 'clojure.repl'
    return s:Lookup(s:repl_ns(), 'doc', a:symbol)
  endif

  let info = fireplace#info(a:symbol)
  echo '-------------------------'
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
  let items = []
  for line in lines
    if line =~# '\t.*\t.*\t'
      let item = {'text': line}
      let [resource, lnum, type, name] = split(line, "\t", 1)
      let item.lnum = lnum
      let item.type = (type ==# 'fail' ? 'W' : 'E')
      let item.text = name
      if resource ==# 'NO_SOURCE_FILE'
        let resource = ''
        let item.lnum = 0
      endif
      let item.filename = fireplace#findresource(resource, a:path)
      if empty(item.filename)
        let item.lnum = 0
      endif
    else
      let item = s:qfmassage(line, a:path)
    endif
    call add(items, item)
  endfor
  if a:id
    call setqflist([], 'a', {'id': a:id, 'items': items})
  else
    call setqflist(items, 'a')
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
