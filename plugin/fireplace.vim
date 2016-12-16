" fireplace.vim - Clojure REPL support
" Maintainer:   Tim Pope <http://tpo.pe/>
" Version:      1.1
" GetLatestVimScripts: 4978 1 :AutoInstall: fireplace.vim

if exists("g:loaded_fireplace") || v:version < 700 || &cp
  finish
endif
let g:loaded_fireplace = 1

" Section: File type

augroup fireplace_file_type
  autocmd!
  autocmd BufNewFile,BufReadPost *.clj setfiletype clojure
augroup END

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
  if !exists('s:zipinfo')
    if executable('zipinfo')
      let s:zipinfo = 'zipinfo -1 '
    elseif executable('jar')
      let s:zipinfo = 'jar tf '
    elseif executable('python')
      let s:zipinfo = 'python -c '.shellescape('import zipfile, sys; print chr(10).join(zipfile.ZipFile(sys.argv[1]).namelist())').' '
    else
      let s:zipinfo = ''
    endif
  endif

  if !has_key(s:jar_contents, a:path) && has('python')
    python import vim, zipfile
    python vim.command("let s:jar_contents[a:path] = split('" + "\n".join(zipfile.ZipFile(vim.eval('a:path')).namelist()) + "', \"\n\")")
  elseif !has_key(s:jar_contents, a:path) && !empty(s:zipinfo)
    let s:jar_contents[a:path] = split(system(s:zipinfo.shellescape(a:path)), "\n")
    if v:shell_error
      let s:jar_contents[a:path] = []
    endif
  endif

  return copy(get(s:jar_contents, a:path, []))
endfunction

function! fireplace#eval_complete(A, L, P) abort
  let prefix = matchstr(a:A, '\%(.* \|^\)\%(#\=[\[{('']\)*')
  let keyword = a:A[strlen(prefix) : -1]
  return sort(map(fireplace#omnicomplete(0, keyword), 'prefix . v:val.word'))
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

  return strpart(expr, 0, p) . '__prefix__' . strpart(expr, p)
endfunction

function! fireplace#omnicomplete(findstart, base) abort
  if a:findstart
    let line = getline('.')[0 : col('.')-2]
    return col('.') - strlen(matchstr(line, '\k\+$')) - 1
  else
    try

      if fireplace#op_available('complete')
        let response = fireplace#message({
              \ 'op': 'complete',
              \ 'symbol': a:base,
              \ 'extra-metadata': ['arglists', 'doc'],
              \ 'context': s:get_complete_context()
              \ })
        let trans = '{"word": (v:val =~# ''[./]'' ? "" : matchstr(a:base, ''^.\+/'')) . v:val}'
        let value = get(response[0], 'value', get(response[0], 'completions'))
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

augroup fireplace_completion
  autocmd!
  autocmd FileType clojure setlocal omnifunc=fireplace#omnicomplete
augroup END

" Section: REPL client

let s:repl = {"requires": {}}

if !exists('s:repls')
  let s:repls = []
  let s:repl_paths = {}
  let s:repl_portfiles = {}
endif

function! s:repl.path() dict abort
  return self.connection.path()
endfunction

function! s:conn_try(connection, function, ...) abort
  try
    return call(a:connection[a:function], a:000, a:connection)
  catch /^\w\+ Connection Error:/
    call s:unregister_connection(a:connection)
    throw v:exception
  endtry
endfunction

function! s:repl.message(payload, ...) dict abort
  if has_key(a:payload, 'ns') && a:payload.ns !=# self.user_ns()
    let ignored_error = self.preload(a:payload.ns)
  endif
  return call('s:conn_try', [self.connection, 'message', a:payload] + a:000, self)
endfunction

function! s:repl.preload(lib) dict abort
  if !empty(a:lib) && a:lib !=# self.user_ns() && !get(self.requires, a:lib)
    let reload = has_key(self.requires, a:lib) ? ' :reload' : ''
    let self.requires[a:lib] = 0
    let clone = s:conn_try(self.connection, 'clone')
    if self.user_ns() ==# 'user'
      let qsym = s:qsym(a:lib)
      let expr = '(when-not (find-ns '.qsym.') (try'
            \ . ' (#''clojure.core/load-one '.qsym.' true true)'
            \ . ' (catch Exception e (when-not (find-ns '.qsym.') (throw e)))))'
    else
      let expr = '(ns '.self.user_ns().' (:require '.a:lib.reload.'))'
    endif
    try
      let result = clone.eval(expr, {'ns': self.user_ns()})
    finally
      call clone.close()
    endtry
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
      let result = fireplace#session_eval(':cljs/quit', {})
      call remove(self.piggiebacks, 0)
    endif
    return {}
  endif

  let connection = s:conn_try(self.connection, 'clone')
  if empty(a:arg)
    let arg = '(cljs.repl.rhino/repl-env)'
  elseif a:arg =~# '^\d\{1,5}$'
    let replns = 'weasel.repl.websocket'
    if has_key(connection.eval("(require '" . replns . ")"), 'ex')
      let replns = 'cljs.repl.browser'
      call connection.eval("(require '" . replns . ")")
    endif
    let port = matchstr(a:arg, '^\d\{1,5}$')
    let arg = '('.replns.'/repl-env :port '.port.')'
  else
    let arg = a:arg
  endif
  let response = connection.eval('(cemerick.piggieback/cljs-repl'.' '.arg.')')

  if empty(get(response, 'ex'))
    call insert(self.piggiebacks, extend({'connection': connection}, deepcopy(s:piggieback)))
    return {}
  endif
  call connection.close()
  return response
endfunction

function! s:piggieback.user_ns() abort
  return 'cljs.user'
endfunction

function! s:piggieback.eval(expr, options) abort
  let options = copy(a:options)
  if has_key(options, 'file_path')
    call remove(options, 'file_path')
  endif
  return call(s:repl.eval, [a:expr, options], self)
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
  return s:conn_try(self.connection, 'eval', a:expr, a:options)
endfunction

function! s:register_connection(conn, ...) abort
  call insert(s:repls, extend({'connection': a:conn, 'piggiebacks': []}, deepcopy(s:repl)))
  if a:0 && a:1 !=# ''
    let s:repl_paths[a:1] = s:repls[0]
  endif
  return s:repls[0]
endfunction

function! s:unregister_connection(conn) abort
  call filter(s:repl_paths, 'v:val.connection.transport isnot# a:conn.transport')
  call filter(s:repls, 'v:val.connection.transport isnot# a:conn.transport')
  call filter(s:repl_portfiles, 'v:val.connection.transport isnot# a:conn.transport')
endfunction

function! fireplace#register_port_file(portfile, ...) abort
  let old = get(s:repl_portfiles, a:portfile, {})
  if has_key(old, 'time') && getftime(a:portfile) !=# old.time
    call s:unregister_connection(old.connection)
    let old = {}
  endif
  if empty(old) && getfsize(a:portfile) > 0
    let port = matchstr(readfile(a:portfile, 'b', 1)[0], '\d\+')
    try
      let conn = fireplace#nrepl_connection#open(port)
      let s:repl_portfiles[a:portfile] = {
            \ 'time': getftime(a:portfile),
            \ 'connection': conn}
      call s:register_connection(conn, a:0 ? a:1 : '')
      return conn
    catch /^nREPL Connection Error:/
      if &verbose
        echohl WarningMSG
        echomsg v:exception
        echohl None
      endif
      return {}
    endtry
  else
    return get(old, 'connection', {})
  endif
endfunction

" Section: :Connect

command! -bar -complete=customlist,s:connect_complete -nargs=* FireplaceConnect :exe s:Connect(<f-args>)

function! fireplace#input_host_port() abort
  let arg = input('Host> ', 'localhost')
  if arg ==# ''
    return ''
  endif
  echo "\n"
  let arg .= ':' . input('Port> ')
  if arg =~# ':$'
    return ''
  endif
  echo "\n"
  return arg
endfunction

function! s:protos() abort
  return map(split(globpath(&runtimepath, 'autoload/fireplace/*_connection.vim'), "\n"), 'fnamemodify(v:val, ":t")[0:-16]')
endfunction

function! s:connect_complete(A, L, P) abort
  let proto = matchstr(a:A, '\w\+\ze://')
  if proto ==# ''
    let options = map(s:protos(), 'v:val."://"')
  else
    let rest = matchstr(a:A, '://\zs.*')
    try
      let options = fireplace#{proto}_connection#complete(rest)
    catch /^Vim(let):E117/
      let options = ['localhost:']
    endtry
    call map(options, 'proto."://".v:val')
  endif
  if a:A !=# ''
    call filter(options, 'v:val[0 : strlen(a:A)-1] ==# a:A')
  endif
  return options
endfunction

function! s:Connect(...) abort
  if (a:0 ? a:1 : '') =~# '^\w\+://'
    let [proto, arg] = split(a:1, '://')
  elseif (a:0 ? a:1 : '') =~# '^\%([[:alnum:].-]\+:\)\=\d\+$'
    let [proto, arg] = ['nrepl', a:1]
  elseif a:0
    return 'echoerr '.string('Usage: :Connect proto://...')
  else
    let protos = s:protos()
    if empty(protos)
      return 'echoerr '.string('No protocols available')
    endif
    let proto = s:inputlist('Protocol> ', protos)
    if proto ==# ''
      return
    endif
    redraw!
    echo ':Connect'
    echo 'Protocol> '.proto
    let arg = fireplace#{proto}_connection#prompt()
  endif
  try
    let connection = fireplace#{proto}_connection#open(arg)
  catch /.*/
    return 'echoerr '.string(v:exception)
  endtry
  if type(connection) !=# type({}) || empty(connection)
    return ''
  endif
  let client = s:register_connection(connection)
  echo 'Connected to '.proto.'://'.arg
  let path = fnamemodify(exists('b:java_root') ? b:java_root : fnamemodify(expand('%'), ':p:s?.*\zs[\/]src[\/].*??'), ':~')
  let root = a:0 > 1 ? expand(a:2) : input('Scope connection to: ', path, 'dir')
  if root !=# '' && root !=# '-'
    let s:repl_paths[fnamemodify(root, ':p:s?.\zs[\/]$??')] = client
  endif
  return ''
endfunction

function! s:piggieback(arg, remove) abort
  let response = fireplace#platform().piggieback(a:arg, a:remove)
  call s:output_response(response)
endfunction

augroup fireplace_connect
  autocmd!
  autocmd FileType clojure command! -buffer -bar  -complete=customlist,s:connect_complete -nargs=*
        \ Connect FireplaceConnect <args>
  autocmd FileType clojure command! -buffer -bang -complete=customlist,fireplace#eval_complete -nargs=*
        \ Piggieback call s:piggieback(<q-args>, <bang>0)
augroup END

" Section: Java runner

let s:oneoff_pr  = tempname()
let s:oneoff_ex  = tempname()
let s:oneoff_stk = tempname()
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
  call writefile([], s:oneoff_stk, 'b')
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
        \   '      (spit '.s:str(s:oneoff_ex).' (class e))' .
        \   '      (spit '.s:str(s:oneoff_stk).' (apply str (interpose "\n" (.getStackTrace e))))))' .
        \   '  nil)')
  let captured = system(command)
  let result = {}
  let result.value = join(readfile(s:oneoff_pr, 'b'), "\n")
  let result.out   = join(readfile(s:oneoff_out, 'b'), "\n")
  let result.err   = join(readfile(s:oneoff_err, 'b'), "\n")
  let result.ex    = join(readfile(s:oneoff_ex, 'b'), "\n")
  let result.stacktrace = readfile(s:oneoff_stk)
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

let s:oneoff = {}

function! s:oneoff.user_ns() abort
  return 'user'
endfunction

function! s:oneoff.path() dict abort
  return self._path
endfunction

function! s:oneoff.eval(expr, options) dict abort
  if !empty(get(a:options, 'session', 1))
    throw 'Fireplace: no live REPL connection'
  endif
  let result = s:spawning_eval(join(self.path(), has('win32') ? ';' : ':'),
        \ a:expr, get(a:options, 'ns', self.user_ns()))
  if has_key(a:options, 'id')
    let result.id = a:options.id
  endif
  return result
endfunction

function! s:oneoff.message(...) abort
  throw 'Fireplace: no live REPL connection'
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
  return s:to_ns(path ==# '' ? fireplace#client(buffer).user_ns() : path)
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

function! s:repl_ns() abort
  let buf = a:0 ? a:1 : s:buf()
  if fnamemodify(bufname(buf), ':e') ==# 'cljs'
    return 'cljs.repl'
  endif
    return 'clojure.repl'
  endif
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

function! s:path_extract(path)
  let path = []
  if a:path =~# '\.jar'
    for elem in split(substitute(a:path, ',$', '', ''), ',')
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
    if getftime(k) != v.time
      call s:unregister_connection(v.connection)
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
  throw 'Fireplace: :Connect to a REPL or install classpath.vim'
endfunction

function! fireplace#client(...) abort
  let buf = a:0 ? a:1 : s:buf()
  let client = fireplace#platform(buf)
  if fnamemodify(bufname(buf), ':e') ==# 'cljs'
    if !has_key(client, 'connection')
      throw 'Fireplace: no live REPL connection'
    endif
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
  return call(client.message, [payload] + a:000, client)
endfunction

function! fireplace#op_available(op) abort
  try
    let client = fireplace#platform()
    if has_key(client, 'connection')
      return client.connection.has_op(a:op)
    endif
  catch /^Fireplace: :Connect to a REPL/
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

function! s:temp_response(response) abort
  let output = []
  if get(a:response, 'err', '') !=# ''
    let output = map(split(a:response.err, "\n"), '";!!".v:val')
  endif
  if get(a:response, 'out', '') !=# ''
    let output = map(split(a:response.out, "\n"), '";".v:val')
  endif
  if has_key(a:response, 'value')
    let output += [a:response.value]
  endif
  let temp = tempname().'.clj'
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
    let a:entry.tempfile = s:temp_response(a:entry.response)
  endif
  let s:qffiles[a:entry.tempfile] = a:entry
  return {'filename': a:entry.tempfile, 'text': a:entry.code, 'type': 'E'}
endfunction

function! s:qfhistory() abort
  let list = []
  for entry in reverse(s:history)
    if !has_key(entry, 'tempfile')
      let entry.tempfile = s:temp_response(entry.response)
    endif
    call extend(list, [s:qfentry(entry)])
  endfor
  return list
endfunction

function! fireplace#session_eval(expr, ...) abort
  let response = s:eval(a:expr, a:0 ? a:1 : {})

  if !empty(get(response, 'value', '')) || !empty(get(response, 'err', ''))
    call insert(s:history, {'buffer': bufnr(''), 'code': a:expr, 'ns': fireplace#ns(), 'response': response})
  endif
  if len(s:history) > &history
    call remove(s:history, &history, -1)
  endif

  if !empty(get(response, 'stacktrace', []))
    let nr = 0
    if has_key(s:qffiles, expand('%:p'))
      let nr = winbufnr(s:qffiles[expand('%:p')].buffer)
    endif
    if nr != -1
      call setloclist(nr, fireplace#quickfix_for(response.stacktrace))
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
  elseif has_key(response, 'value')
    return response.value
  else
    let err = 'fireplace.vim: Something went wrong: '.string(response)
  endif
  throw err
endfunction

function! fireplace#eval(...) abort
  return call('fireplace#session_eval', a:000)
endfunction

function! fireplace#echo_session_eval(expr, ...) abort
  try
    echo fireplace#session_eval(a:expr, a:0 ? a:1 : {})
  catch /^Clojure:/
  catch
    echohl ErrorMSG
    echomsg v:exception
    echohl NONE
  endtry
  return ''
endfunction

function! fireplace#evalprint(expr) abort
  return fireplace#echo_session_eval(a:expr)
endfunction

function! fireplace#macroexpand(fn, form) abort
  return fireplace#evalprint('('.a:fn.' (quote '.a:form.'))')
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
    return empty(response.value) ? '' : eval(response.value)
  else
    let err = 'fireplace.vim: Something went wrong: '.string(response)
  endif
  throw err
endfunction

function! fireplace#query(expr, ...) abort
  return fireplace#evalparse(a:expr, a:0 ? a:1 : {})
endfunction

" Section: Quickfix

function! s:qfmassage(line, path) abort
  let entry = {'text': a:line}
  let match = matchlist(a:line, '\(\S\+\)\s\=(\(\S\+\))')
  if !empty(match)
    let [_, class, file; __] = match
    if file =~# '^NO_SOURCE_FILE:' || file !~# ':'
      let entry.resource = ''
      let entry.lnum = 0
    else
      let truncated = substitute(class, '\.[A-Za-z0-9_]\+\%([$/].*\)$', '', '')
      let entry.resource = tr(truncated, '.', '/').'/'.split(file, ':')[0]
      let entry.lnum = split(file, ':')[-1]
    endif
    let entry.filename = fireplace#findresource(entry.resource, a:path)
    if empty(entry.filename)
      let entry.lnum = 0
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

function! s:massage_quickfix() abort
  let p = substitute(matchstr(','.&errorformat, ',classpath\zs\%(\\.\|[^\,]\)*'), '\\\ze[\,%]', '', 'g')
  if empty(p)
    return
  endif
  let path = p[0] ==# ',' ? s:path_extract(p[1:-1]) : split(p[1:-1], p[0])
  let qflist = getqflist()
  for entry in qflist
    call extend(entry, s:qfmassage(get(entry, 'text', ''), path))
  endfor
  call setqflist(qflist, 'replace')
endfunction

augroup fireplace_quickfix
  autocmd!
  autocmd QuickFixCmdPost make,cfile,cgetfile call s:massage_quickfix()
augroup END

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
    if fireplace#client().user_ns() ==# 'user'
      return repeat("\n", line("'<")-1) . repeat(" ", col("'<")-1) . @@
    else
      return @@
    endif
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
    let expr = s:opfunc(a:type)
    let @@ = fireplace#session_eval(matchstr(expr, '^\n\+').expr).matchstr(expr, '\n\+$')
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

function! s:macroexpandop(type) abort
  call fireplace#macroexpand("clojure.walk/macroexpand-all", s:opfunc(a:type))
endfunction

function! s:macroexpand1op(type) abort
  call fireplace#macroexpand("macroexpand-1", s:opfunc(a:type))
endfunction

function! s:printop(type) abort
  let s:todo = s:opfunc(a:type)
  call feedkeys("\<Plug>FireplacePrintLast")
endfunction

function! s:print_last() abort
  call fireplace#echo_session_eval(s:todo, {'file_path': s:buffer_path()})
  return ''
endfunction

function! s:editop(type) abort
  call feedkeys(eval('"\'.&cedit.'"') . "\<Home>", 'n')
  let input = s:input(substitute(substitute(substitute(
        \ s:opfunc(a:type), "\s*;[^\n\"]*\\%(\n\\@=\\|$\\)", '', 'g'),
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
    let options.file_path = s:buffer_path()
    if expand('%:e') ==# 'cljs'
      "leading line feed don't work on cljs repl
      let expr = ''
    else
      let expr = repeat("\n", line1-1).repeat(" ", col1-1)
    endif
    if line1 == line2
      let expr .= getline(line1)[col1-1 : col2-1]
    else
      let expr .= getline(line1)[col1-1 : -1] . "\n"
            \ . join(map(getline(line1+1, line2-1), 'v:val . "\n"'))
            \ . getline(line2)[0 : col2-1]
    endif
    if a:bang
      exe line1.','.line2.'delete _'
    endif
  endif
  if a:bang
    try
      let result = fireplace#session_eval(expr, options)
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
      return fireplace#session_eval(input)
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

  if get(g:, 'fireplace_no_maps') | return | endif

  nmap <buffer> cp <Plug>FireplacePrint
  nmap <buffer> cpp <Plug>FireplaceCountPrint

  nmap <buffer> c! <Plug>FireplaceFilter
  nmap <buffer> c!! <Plug>FireplaceCountFilter

  nmap <buffer> cm <Plug>FireplaceMacroExpand
  nmap <buffer> cmm <Plug>FireplaceCountMacroExpand
  nmap <buffer> c1m <Plug>Fireplace1MacroExpand
  nmap <buffer> c1mm <Plug>FireplaceCount1MacroExpand

  nmap <buffer> cq <Plug>FireplaceEdit
  nmap <buffer> cqq <Plug>FireplaceCountEdit

  nmap <buffer> cqp <Plug>FireplacePrompt
  exe 'nmap <buffer> cqc <Plug>FireplacePrompt' . &cedit . 'i'

  map! <buffer> <C-R>( <Plug>FireplaceRecall
endfunction

function! s:set_up_historical() abort
  setlocal readonly nomodifiable
  nnoremap <buffer><silent>q :bdelete<CR>
endfunction

function! s:cmdwinenter() abort
  setlocal filetype=clojure
endfunction

function! s:cmdwinleave() abort
  setlocal filetype< omnifunc<
endfunction

augroup fireplace_eval
  autocmd!
  autocmd FileType clojure call s:set_up_eval()
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
  if expand('%:e') ==# 'cljs'
    let cmd = '(load-file '.s:str(tr(a:ns ==# '' ? fireplace#ns() : a:ns, '-.', '_/').'.cljs').')'
  else
    let cmd = ('(clojure.core/require '.s:qsym(a:ns ==# '' ? fireplace#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').')')
  endif
  if a:echo
    echo cmd
  endif
  try
    call fireplace#session_eval(cmd, {'ns': fireplace#client().user_ns()})
    return ''
  catch /^Clojure:.*/
    return ''
  endtry
endfunction

function! s:set_up_require() abort
  command! -buffer -bar -bang -complete=customlist,fireplace#ns_complete -nargs=? Require :exe s:Require(<bang>0, 1, <q-args>)

  if get(g:, 'fireplace_no_maps') | return | endif
  nnoremap <silent><buffer> cpr :<C-R>=expand('%:e') ==# 'cljs' ? 'Require' : 'RunTests'<CR><CR>
endfunction

augroup fireplace_require
  autocmd!
  autocmd FileType clojure call s:set_up_require()
augroup END

" Section: Go to source

function! fireplace#info(symbol) abort
  if fireplace#op_available('info')
    let response = fireplace#message({'op': 'info', 'symbol': a:symbol})[0]
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
  elseif has_key(info, 'file')
    let fpath = ''
    if get(info, 'file') =~# '^/\|^\w:\\'
      let file = info.file
    elseif get(info, 'file') =~# '^file:'
      let file = substitute(strpart(info.file,5), '/', s:slash(), 'g')
    end

    if !empty(fpath) && filereadable(fpath)
      let file = fpath
    end
  endif

  if !empty(file) && !empty(get(info, 'line', ''))
    return '+' . info.line . ' ' . fnameescape(file)
  endif
  return ''
endfunction

function! s:Edit(cmd, keyword) abort
  try
    if a:keyword =~# '^\k\+[/.]$'
      let location = fireplace#findfile(a:keyword[0: -2])
    elseif a:keyword =~# '^\k\+\.[^/.]\+$'
      let location = fireplace#findfile(a:keyword)
    else
      let location = fireplace#source(a:keyword)
    endif
  catch /^Clojure:/
    return ''
  endtry
  if location !=# ''
    if matchstr(location, '^+\d\+ \zs.*') ==# fnameescape(expand('%:p')) && a:cmd ==# 'edit'
      normal! m'
      return matchstr(location, '\d\+')
    else
      return a:cmd.' '.location.'|let &l:path = '.string(&l:path)
    endif
  endif
  let v:errmsg = "Couldn't find source for ".a:keyword
  return 'echoerr v:errmsg'
endfunction

nnoremap <silent> <Plug>FireplaceDjump :<C-U>exe <SID>Edit('edit', expand('<cword>'))<CR>
nnoremap <silent> <Plug>FireplaceDsplit :<C-U>exe <SID>Edit('split', expand('<cword>'))<CR>
nnoremap <silent> <Plug>FireplaceDtabjump :<C-U>exe <SID>Edit('tabedit', expand('<cword>'))<CR>

function! s:set_up_source() abort
  setlocal define=^\\s*(def\\w*
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Djump  :exe s:Edit('edit', <q-args>)
  command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Dsplit :exe s:Edit('split', <q-args>)

  if get(g:, 'fireplace_no_maps') | return | endif
  nmap <buffer> [<C-D>     <Plug>FireplaceDjump
  nmap <buffer> ]<C-D>     <Plug>FireplaceDjump
  nmap <buffer> <C-W><C-D> <Plug>FireplaceDsplit
  nmap <buffer> <C-W>d     <Plug>FireplaceDsplit
  nmap <buffer> <C-W>gd    <Plug>FireplaceDtabjump
endfunction

augroup fireplace_source
  autocmd!
  autocmd FileType clojure call s:set_up_source()
augroup END

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

let s:iskeyword = '[[:alnum:]_=?!#$%&*+|./<>:-]'
let s:token = '^\%(#"\%(\\\@<!\%(\\\\\)*\\"\|[^"]\)*"\|"\%(\\.\|[^"]\)*"\|[[:space:],]\+\|\%(;\|#!\)[^'."\n".']*\|\~@\|#[[:punct:]]\|'.s:iskeyword.'\+\|\\\%(space\|tab\|newline\|return\|.\)\|.\)'
function! s:read_token(str, pos) abort
  let pos = a:pos
  let match = ' '
  while match =~# '^[[:space:],;]'
    let match = matchstr(a:str, s:token, pos)
    let pos += len(match)
  endwhile
  if empty(match)
    throw 'fireplace: Clojure parse error'
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
  let keyword_group = '[A-Za-z0-9_?*!+/=<>.-]'
  let lines = join(head, "\n")
  let match = matchstr(lines, '\C^(\s*ns\s\+.*')
  if len(match)
    try
      return s:read(match, 0)[0]
    catch /^fireplace: Clojure parse error$/
    endtry
  endif
  return []
endfunction

function! fireplace#resolve_alias(name) abort
  if a:name =~# '\.'
    return a:name
  endif
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
  let file = expand('<cfile>')
  if file =~# '^\w[[:alnum:]_/]*$' &&
        \ synIDattr(synID(line("."),col("."),1),"name") =~# 'String'
    let file = substitute(expand('%:p'), '[^\/:]*$', '', '').file
  elseif file =~# '^[^/]*/[^/.]*$' && file =~# '^\k\+$'
    let [file, jump] = split(file, "/")
    let file = fireplace#resolve_alias(file)
    if file !~# '\.' && fireplace#op_available('info')
      let res = fireplace#message({'op': 'info', 'symbol': file})
      let file = get(get(res, 0, {}), 'ns', file)
    endif
    let file = tr(file, '.-', '/_')
  elseif file =~# '^\w[[:alnum:].-]*$'
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
  cmap <buffer> <C-R><C-F> <Plug><cfile>
  cmap <buffer> <C-R><C-P> <Plug><cpath>
  if empty(mapcheck('gf', 'n'))
    nmap <buffer> gf         <Plug>FireplaceEditFile
  endif
  if empty(mapcheck('<C-W>f', 'n'))
    nmap <buffer> <C-W>f     <Plug>FireplaceSplitFile
  endif
  if empty(mapcheck('<C-W><C-F>', 'n'))
    nmap <buffer> <C-W><C-F> <Plug>FireplaceSplitFile
  endif
  if empty(mapcheck('<C-W>gf', 'n'))
    nmap <buffer> <C-W>gf    <Plug>FireplaceTabeditFile
  endif
endfunction

augroup fireplace_go_to_file
  autocmd!
  autocmd FileType clojure call s:set_up_go_to_file()
augroup END

" Section: Documentation

function! s:Lookup(ns, macro, arg) abort
  try
    let response = s:eval('('.a:ns.'/'.a:macro.' '.a:arg.')')
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

  if get(info, 'arglists-str', 'nil') !=# 'nil'
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

  elseif get(info, 'macro', 'nil') !=# 'nil'
    echo "Macro"
  endif

  if !empty(get(info, 'doc', ''))
    echo '  ' . info.doc
  endif

  return ''
endfunction

function! s:K() abort
  let word = expand('<cword>')
  let java_candidate = matchstr(word, '^\%(\w\+\.\)*\u\l[[:alnum:]$]*\ze\%(\.\|\/\w\+\)\=$')
  if java_candidate !=# ''
    return 'Javadoc '.java_candidate
  else
    return 'Doc '.word
  endif
endfunction

nnoremap <Plug>FireplaceK :<C-R>=<SID>K()<CR><CR>
nnoremap <Plug>FireplaceSource :Source <C-R><C-W><CR>

function! s:set_up_doc() abort
  command! -buffer -nargs=1 FindDoc :exe s:Lookup(s:repl_ns(), 'find-doc', printf('#"%s"', <q-args>))
  command! -buffer -bar -nargs=1 Javadoc :exe s:Lookup('clojure.java.javadoc', 'javadoc', <q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Doc     :exe s:Doc(<q-args>)
  command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Source  :exe s:Lookup(s:repl_ns(), 'source', <q-args>)
  setlocal keywordprg=:Doc

  if get(g:, 'fireplace_no_maps') | return | endif
  if empty(mapcheck('K', 'n'))
    nmap <buffer> K <Plug>FireplaceK
  endif
  nmap <buffer> [d <Plug>FireplaceSource
  nmap <buffer> ]d <Plug>FireplaceSource
endfunction

augroup fireplace_doc
  autocmd!
  autocmd FileType clojure call s:set_up_doc()
augroup END

" Section: Tests

function! fireplace#capture_test_run(expr, ...) abort
  let expr = '(try'
        \ . ' ' . (a:0 ? a:1 : '')
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
  let qflist = []
  let response = s:eval(expr, {'session': 0})
  if !has_key(response, 'out')
    call setqflist(fireplace#quickfix_for(get(response, 'stacktrace', [])))
    return s:output_response(response)
  endif
  for line in split(response.out, "\r\\=\n")
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
      let entry.filename = fireplace#findresource(resource, fireplace#path())
      if empty(entry.filename)
        let entry.lnum = 0
      endif
    else
      let entry = s:qfmassage(line, fireplace#path())
    endif
    call add(qflist, entry)
  endfor
  call setqflist(qflist)
  let was_qf = &buftype ==# 'quickfix'
  botright cwindow
  if &buftype ==# 'quickfix' && !was_qf
    wincmd p
  endif
  for winnr in range(1, winnr('$'))
    if getwinvar(winnr, '&buftype') ==# 'quickfix'
      call setwinvar(winnr, 'quickfix_title', a:expr)
      return
    endif
  endfor
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
  call fireplace#capture_test_run(join(expr, ' '), pre)
  echo join(expr, ' ')
endfunction

function! s:set_up_tests() abort
  command! -buffer -bar -bang -range=0 -nargs=*
        \ -complete=customlist,fireplace#ns_complete RunTests
        \ call s:RunTests(<bang>0, <line1> == 0 ? -1 : <count>, <f-args>)
  command! -buffer -bang -nargs=* RunAllTests
        \ call s:RunTests(<bang>0, -1, <f-args>)
endfunction

augroup fireplace_tests
  autocmd!
  autocmd FileType clojure call s:set_up_tests()
augroup END
