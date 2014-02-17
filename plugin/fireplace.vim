" fireplace.vim - Clojure REPL tease
" Maintainer:   Tim Pope <http://tpo.pe/>

if exists("g:loaded_fireplace") || v:version < 700 || &cp
  finish
endif
let g:loaded_fireplace = 1

" File type {{{1

augroup fireplace_file_type
  autocmd!
  autocmd BufNewFile,BufReadPost *.clj setfiletype clojure
augroup END

" }}}1
" Escaping {{{1

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

" }}}1
" Completion {{{1

let s:jar_contents = {}

function! fireplace#jar_contents(path) abort
  if !exists('s:zipinfo')
    if executable('zipinfo')
      let s:zipinfo = 'zipinfo -1 '
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

function! fireplace#omnicomplete(findstart, base) abort
  if a:findstart
    let line = getline('.')[0 : col('.')-2]
    return col('.') - strlen(matchstr(line, '\k\+$')) - 1
  else
    try
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

" }}}1
" REPL client {{{1

let s:repl = {"requires": {}}

if !exists('s:repls')
  let s:repls = []
  let s:repl_paths = {}
endif

function! s:repl.user_ns() abort
  return 'user'
endfunction

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

function! s:repl.eval(expr, options) dict abort
  if has_key(a:options, 'ns') && a:options.ns !=# self.user_ns()
    let error = self.preload(a:options.ns)
    if !empty(error)
      return error
    endif
  endif
  return s:conn_try(self.connection, 'eval', a:expr, a:options)
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
    try
      let result = clone.eval('(ns '.self.user_ns().' (:require '.a:lib.reload.'))', {'ns': self.user_ns()})
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
      call remove(self.piggiebacks, 0)
    endif
    return {}
  endif
  if empty(a:arg)
    let arg = ''
  else
    let arg = ' :repl-env ' . a:arg
  endif
  let connection = s:conn_try(self.connection, 'clone')
  let response = connection.eval('(cemerick.piggieback/cljs-repl'.arg.')')

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
endfunction

" }}}1
" :Connect {{{1

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
  return map(split(globpath(&runtimepath, 'autoload/*/fireplace_connection.vim'), "\n"), 'fnamemodify(v:val, ":h:t")')
endfunction

function! s:connect_complete(A, L, P) abort
  let proto = matchstr(a:A, '\w\+\ze://')
  if proto ==# ''
    let options = map(s:protos(), 'v:val."://"')
  else
    let rest = matchstr(a:A, '://\zs.*')
    try
      let options = {proto}#fireplace_connection#complete(rest)
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
    let arg = {proto}#fireplace_connection#prompt()
  endif
  try
    let connection = {proto}#fireplace_connection#open(arg)
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
  autocmd FileType clojure command! -bar -complete=customlist,s:connect_complete -nargs=* Connect :FireplaceConnect <args>
  autocmd FileType clojure command!      -complete=customlist,fireplace#eval_complete -bang -nargs=* Piggieback :call s:piggieback(<q-args>, <bang>0)
augroup END

" }}}1
" Java runner {{{1

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
        \   '(clojure.core/binding [*out* (java.io.FileWriter. '.s:str(s:oneoff_out).')' .
        \   '                       *err* (java.io.FileWriter. '.s:str(s:oneoff_err).')]' .
        \   '  (try' .
        \   '    (clojure.core/require ''clojure.repl) '.ns.'(clojure.core/spit '.s:str(s:oneoff_pr).' (clojure.core/pr-str (clojure.core/eval (clojure.core/read-string (clojure.core/slurp '.s:str(s:oneoff_in).')))))' .
        \   '    (catch Exception e' .
        \   '      (clojure.core/spit *err* (.toString e))' .
        \   '      (clojure.core/spit '.s:str(s:oneoff_ex).' (clojure.core/class e))' .
        \   '      (clojure.core/spit '.s:str(s:oneoff_stk).' (clojure.core/apply clojure.core/str (clojure.core/interpose "\n" (.getStackTrace e))))))' .
        \   '  nil)')
  let captured = system(command)
  let result = {}
  let result.value = join(readfile(s:oneoff_pr, 'b'), "\n")
  let result.out   = join(readfile(s:oneoff_out, 'b'), "\n")
  let result.err   = join(readfile(s:oneoff_err, 'b'), "\n")
  let result.ex    = join(readfile(s:oneoff_ex, 'b'), "\n")
  let result.stacktrace = readfile(s:oneoff_stk)
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
  return classpath#split(self.classpath)
endfunction

function! s:oneoff.eval(expr, options) dict abort
  if &verbose && !empty(get(a:options, 'session', 1))
    echohl WarningMSG
    echomsg "No REPL found. Running java clojure.main ..."
    echohl None
  endif
  return s:spawning_eval(self.classpath, a:expr, get(a:options, 'ns', self.user_ns()))
endfunction

function! s:oneoff.message(...) abort
  throw 'No live REPL connection'
endfunction

let s:oneoff.piggieback = s:oneoff.message

" }}}1
" Client {{{1

function! s:buf() abort
  if exists('s:input')
    return s:input
  elseif has_key(s:qffiles, expand('%:p'))
    return s:qffiles[expand('%:p')].buffer
  else
    return '%'
  endif
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

function! fireplace#path(...) abort
  let buf = a:0 ? a:1 : s:buf()
  for repl in s:repls
    if s:includes_file(fnamemodify(bufname(buf), ':p'), repl.path())
      return repl.path()
    endif
  endfor
  if exists('*classpath#from_vim')
    return classpath#split(classpath#from_vim(getbufvar(buf, '&path')))
  endif
  return []
endfunction

function! fireplace#platform(...) abort
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
  if exists('*classpath#from_vim') && fnamemodify(bufname(buf), ':e') =~# '^cljx\=$'
    let cp = classpath#from_vim(getbufvar(buf, '&path'))
    return extend({'classpath': cp, 'nr': bufnr(buf)}, s:oneoff)
  endif
  throw ':Connect to a REPL or install classpath.vim to evaluate code'
endfunction

function! fireplace#client(...) abort
  let buf = a:0 ? a:1 : s:buf()
  let client = fireplace#platform(buf)
  if fnamemodify(bufname(buf), ':e') ==# 'cljs'
    if !has_key(client, 'connection')
      throw ':Connect to a REPL to evaluate code'
    endif
    if empty(client.piggiebacks)
      let result = client.piggieback('')
      if has_key(result, 'ex')
        return result
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
  endif
  return call(client.message, [payload] + a:000, client)
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
        return dir . (exists('+shellslash') && !&shellslash ? '\' : '/') . resource . suffix
      endif
    endfor
  endfor
  return ''
endfunction

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

function! s:output_response(response) abort
  if get(a:response, 'err', '') !=# ''
    echohl ErrorMSG
    echo substitute(a:response.err, '\r\|\n$', '', 'g')
    echohl NONE
  endif
  if get(a:response, 'out', '') !=# ''
    echo substitute(a:response.out, '\r\|\n$', '', 'g')
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

" }}}1
" Eval {{{1

let fireplace#skip = 'synIDattr(synID(line("."),col("."),1),"name") =~? "comment\\|string\\|char"'

function! s:opfunc(type) abort
  let sel_save = &selection
  let cb_save = &clipboard
  let reg_save = @@
  try
    set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
    if a:type =~# '^.$'
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
    return @@
  finally
    let @@ = reg_save
    let &selection = sel_save
    let &clipboard = cb_save
  endtry
endfunction

function! s:filterop(type) abort
  let reg_save = @@
  try
    let expr = s:opfunc(a:type)
    let @@ = matchstr(expr, '^\n\+').fireplace#session_eval(expr).matchstr(expr, '\n\+$')
    if @@ !~# '^\n*$'
      normal! gvp
    endif
  catch /^Clojure:/
    return ''
  finally
    let @@ = reg_save
  endtry
endfunction

function! s:macroexpandop(type) abort
  call fireplace#macroexpand("clojure.walk/macroexpand-all", s:opfunc(a:type))
endfunction

function! s:macroexpand1op(type) abort
  call fireplace#macroexpand("clojure.core/macroexpand-1", s:opfunc(a:type))
endfunction

function! s:printop(type) abort
  let s:todo = s:opfunc(a:type)
  call feedkeys("\<Plug>FireplacePrintLast")
endfunction

function! s:print_last() abort
  call fireplace#echo_session_eval(s:todo)
  return ''
endfunction

function! s:editop(type) abort
  call feedkeys(&cedit . "\<Home>", 'n')
  let input = s:input(substitute(substitute(s:opfunc(a:type), "\s*;[^\n\"]*\\%(\n\\@=\\|$\\)", '', 'g'), '\n\+\s*', ' ', 'g'))
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
    let expr = repeat("\n", line1-1).repeat(" ", col1-1)
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
nnoremap <silent> <Plug>FireplaceCountPrint :<C-U>Eval<CR>

nnoremap <silent> <Plug>FireplaceFilter :<C-U>set opfunc=<SID>filterop<CR>g@
xnoremap <silent> <Plug>FireplaceFilter :<C-U>call <SID>filterop(visualmode())<CR>

nnoremap <silent> <Plug>FireplaceMacroExpand  :<C-U>set opfunc=<SID>macroexpandop<CR>g@
xnoremap <silent> <Plug>FireplaceMacroExpand  :<C-U>call <SID>macroexpandop(visualmode())<CR>
nnoremap <silent> <Plug>FireplaceMacroExpand1 :<C-U>set opfunc=<SID>macroexpand1op<CR>g@
xnoremap <silent> <Plug>FireplaceMacroExpand1 :<C-U>call <SID>macroexpand1op(visualmode())<CR>

nnoremap <silent> <Plug>FireplaceEdit   :<C-U>set opfunc=<SID>editop<CR>g@
xnoremap <silent> <Plug>FireplaceEdit   :<C-U>call <SID>editop(visualmode())<CR>

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

function! s:setup_eval() abort
  command! -buffer -bang -range=0 -nargs=? -complete=customlist,fireplace#eval_complete Eval :exe s:Eval(<bang>0, <line1>, <line2>, <count>, <q-args>)
  command! -buffer -bang -bar -count=1 Last exe s:Last(<bang>0, <count>)

  nmap <buffer> cp <Plug>FireplacePrint
  nmap <buffer> cpp <Plug>FireplaceCountPrint

  nmap <buffer> c! <Plug>FireplaceFilter
  nmap <buffer> c!! <Plug>FireplaceFilterab

  nmap <buffer> cm <Plug>FireplaceMacroExpand
  nmap <buffer> cmm <Plug>FireplaceMacroExpandab
  nmap <buffer> c1m <Plug>FireplaceMacroExpand1
  nmap <buffer> c1mm <Plug>FireplaceMacroExpand1ab

  nmap <buffer> cq <Plug>FireplaceEdit
  nmap <buffer> cqq <Plug>FireplaceEditab

  nmap <buffer> cqp <Plug>FireplacePrompt
  exe 'nmap <buffer> cqc <Plug>FireplacePrompt' . &cedit . 'i'

  map! <buffer> <C-R>( <Plug>FireplaceRecall
endfunction

function! s:setup_historical() abort
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
  autocmd FileType clojure call s:setup_eval()
  autocmd BufReadPost * if has_key(s:qffiles, expand('<amatch>:p')) |
        \   call s:setup_historical() |
        \ endif
  autocmd CmdWinEnter @ if exists('s:input') | call s:cmdwinenter() | endif
  autocmd CmdWinLeave @ if exists('s:input') | call s:cmdwinleave() | endif
augroup END

" }}}1
" :Require {{{1

function! s:Require(bang, ns) abort
  if expand('%:e') ==# 'cljs'
    let cmd = '(load-file '.s:str(tr(a:ns ==# '' ? fireplace#ns() : a:ns, '-.', '_/').'.cljs').')'
  else
    let cmd = ('(clojure.core/require '.s:qsym(a:ns ==# '' ? fireplace#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').')')
  endif
  echo cmd
  try
    call fireplace#session_eval(cmd)
    return ''
  catch /^Clojure:.*/
    return ''
  endtry
endfunction

function! s:setup_require() abort
  command! -buffer -bar -bang -complete=customlist,fireplace#ns_complete -nargs=? Require :exe s:Require(<bang>0, <q-args>)
  nnoremap <silent><buffer> cpr :Require<CR>
endfunction

augroup fireplace_require
  autocmd!
  autocmd FileType clojure call s:setup_require()
augroup END

" }}}1
" Go to source {{{1

function! fireplace#source(symbol) abort
  let cmd =
        \ '(when-let [v (resolve ' . s:qsym(a:symbol) .')]' .
        \ '  (when-let [filepath (:file (meta v))]' .
        \ '    [filepath' .
        \ '     (:line (meta v))]))'
  let result = fireplace#evalparse(cmd)
  if type(result) == type([])
    let file = fireplace#findresource(result[0])
    if !empty(file)
      return '+' . result[1] . ' ' . fnameescape(file)
    endif
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

augroup fireplace_source
  autocmd!
  autocmd FileType clojure setlocal includeexpr=tr(v:fname,'.-','/_')
  autocmd FileType clojure
        \ if expand('%:e') ==# 'cljs' |
        \   setlocal suffixesadd=.cljs,.cljx,.clj,.java |
        \ else |
        \   setlocal suffixesadd=.clj,.cljx,.cljs,.java |
        \ endif
  autocmd FileType clojure setlocal define=^\\s*(def\\w*
  autocmd FileType clojure command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Djump  :exe s:Edit('edit', <q-args>)
  autocmd FileType clojure command! -bar -buffer -nargs=1 -complete=customlist,fireplace#eval_complete Dsplit :exe s:Edit('split', <q-args>)
  autocmd FileType clojure nmap <buffer> [<C-D>     <Plug>FireplaceDjump
  autocmd FileType clojure nmap <buffer> ]<C-D>     <Plug>FireplaceDjump
  autocmd FileType clojure nmap <buffer> <C-W><C-D> <Plug>FireplaceDsplit
  autocmd FileType clojure nmap <buffer> <C-W>d     <Plug>FireplaceDsplit
  autocmd FileType clojure nmap <buffer> <C-W>gd    <Plug>FireplaceDtabjump
augroup END

" }}}1
" Go to file {{{1

function! fireplace#findfile(path) abort
  let path = a:path
  if a:path !~# '/'
    let path = tr(a:path, '.-', '/_')
  else
    let path = substitute(a:path, '^/', '')
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

function! s:GF(cmd, file) abort
  if a:file =~# '^[^/]*/[^/.]*$' && a:file =~# '^\k\+$'
    let [file, jump] = split(a:file, "/")
    if file !~# '\.'
      try
        let file = fireplace#evalparse('((ns-aliases *ns*) '.s:qsym(file).' '.s:qsym(file).')')
      catch /^Clojure:/
      endtry
    endif
  else
    let file = a:file
  endif
  let file = fireplace#findfile(file)
  if file ==# ''
    let v:errmsg = "Couldn't find file for ".a:file
    return 'echoerr v:errmsg'
  endif
  return a:cmd .
        \ (exists('jump') ? ' +sil!\ djump\ ' . jump : '') .
        \ ' ' . fnameescape(file) .
        \ '| let &l:path = ' . string(&l:path)
endfunction

augroup fireplace_go_to_file
  autocmd!
  autocmd FileType clojure nnoremap <silent><buffer> gf         :<C-U>exe <SID>GF('edit', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>f     :<C-U>exe <SID>GF('split', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W><C-F> :<C-U>exe <SID>GF('split', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>gf    :<C-U>exe <SID>GF('tabedit', expand('<cfile>'))<CR>
augroup END

" }}}1
" Documentation {{{1

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

function! s:Lookup(ns, macro, arg) abort
  " doc is in clojure.core in older Clojure versions
  try
    call fireplace#session_eval("(clojure.core/require '".a:ns.") (clojure.core/eval (clojure.core/list (if (ns-resolve 'clojure.core '".a:macro.") 'clojure.core/".a:macro." '".a:ns.'/'.a:macro.") '".a:arg.'))')
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

function! s:Apropos(pattern) abort
  if a:pattern =~# '^#\="'
    let pattern = a:pattern
  elseif a:pattern =~# '^^'
    let pattern = '#"' . a:pattern . '"'
  else
    let pattern = '"' . a:pattern . '"'
  endif
  let matches = fireplace#evalparse('(clojure.repl/apropos '.pattern.')')
  if empty(matches)
    return ''
  endif
  let choice = s:inputlist('Look up docs for:', matches)
  if choice !=# ''
    return 'echo "\n"|Doc '.choice
  else
    return ''
  endif
endfunction

function! s:K() abort
  let word = expand('<cword>')
  let java_candidate = matchstr(word, '^\%(\w\+\.\)*\u\l\w*\ze\%(\.\|\/\w\+\)\=$')
  if java_candidate !=# ''
    return 'Javadoc '.java_candidate
  else
    return 'Doc '.word
  endif
endfunction

nnoremap <Plug>FireplaceK :<C-R>=<SID>K()<CR><CR>
nnoremap <Plug>FireplaceSource :Source <C-R><C-W><CR>

augroup fireplace_doc
  autocmd!
  autocmd FileType clojure nmap <buffer> K  <Plug>FireplaceK
  autocmd FileType clojure nmap <buffer> [d <Plug>FireplaceSource
  autocmd FileType clojure nmap <buffer> ]d <Plug>FireplaceSource
  autocmd FileType clojure command! -buffer -nargs=1 Apropos :exe s:Apropos(<q-args>)
  autocmd FileType clojure command! -buffer -nargs=1 FindDoc :exe s:Lookup('clojure.repl', 'find-doc', printf('#"%s"', <q-args>))
  autocmd FileType clojure command! -buffer -bar -nargs=1 Javadoc :exe s:Lookup('clojure.java.javadoc', 'javadoc', <q-args>)
  autocmd FileType clojure command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Doc     :exe s:Lookup('clojure.repl', 'doc', <q-args>)
  autocmd FileType clojure command! -buffer -bar -nargs=1 -complete=customlist,fireplace#eval_complete Source  :exe s:Lookup('clojure.repl', 'source', <q-args>)
augroup END

" }}}1
" Alternate {{{1

augroup fireplace_alternate
  autocmd!
  autocmd FileType clojure command! -buffer -bar -bang A :exe s:Alternate('edit<bang>')
  autocmd FileType clojure command! -buffer -bar AS :exe s:Alternate('split')
  autocmd FileType clojure command! -buffer -bar AV :exe s:Alternate('vsplit')
  autocmd FileType clojure command! -buffer -bar AT :exe s:Alternate('tabedit')
augroup END

function! fireplace#alternates() abort
  let ns = fireplace#ns()
  if ns =~# '-test$'
    let alt = [ns[0:-6]]
  elseif ns =~# '\.test\.'
    let alt = [substitute(ns, '\.test\.', '.', '')]
  elseif ns =~# '-spec$'
    let alt = [ns[0:-6], ns . '-test']
  elseif ns =~# '\.t-[^\.]*$'
    let alt = [substitute(ns, '\.t-\([^\.]*\)$', '\.\1', '')]
  else
    let alt = [ns . '-test', substitute(ns, '\.', '.test.', ''), ns . '-spec',
             \ substitute(ns, '\.\([^\.]*\)$', '.t-\1', '')]
  endif
  return map(alt, 'tr(v:val, ".-", "/_") . "." . expand("%:e")')
endfunction

function! s:Alternate(cmd) abort
  let alternates = fireplace#alternates()
  for file in alternates
    let path = fireplace#findresource(file)
    if !empty(path)
      return a:cmd . ' ' . fnameescape(path)
    endif
  endfor
  return 'echoerr '.string("Couldn't find " . alternates[0] . " in class path")
endfunction

" }}}1
" Leiningen {{{1

function! s:hunt(start, anchor, pattern) abort
  let root = simplify(fnamemodify(a:start, ':p:s?[\/]$??'))
  if !isdirectory(fnamemodify(root, ':h'))
    return ''
  endif
  let previous = ""
  while root !=# previous
    if filereadable(root . '/' . a:anchor) && join(readfile(root . '/' . a:anchor, '', 50)) =~# a:pattern
      return root
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile
  return ''
endfunction

if !exists('s:leiningen_repls')
  let s:leiningen_repls = {}
  let s:leiningen_paths = {}
endif

function! s:portfile() abort
  if !exists('b:leiningen_root')
    return ''
  endif

  let root = b:leiningen_root
  let portfiles = [root.'/target/repl-port', root.'/target/repl/repl-port', root.'/.nrepl-port']

  for f in portfiles
    if filereadable(f)
      return f
    endif
  endfor
  return ''
endfunction


function! s:leiningen_connect() abort
  for [k, v] in items(s:leiningen_repls)
    if getfsize(v.file) <= 0
      call remove(s:leiningen_repls, k)
      call s:unregister_connection(v.connection)
    endif
  endfor

  let portfile = s:portfile()
  if empty(portfile)
    return
  endif

  if getfsize(portfile) > 0 && getftime(portfile) !=# get(get(s:leiningen_repls, b:leiningen_root, {}), 'time', -1)
    let port = matchstr(readfile(portfile, 'b', 1)[0], '\d\+')
    let s:leiningen_repls[b:leiningen_root] = {'time': getftime(portfile), 'file': portfile}
    try
      let conn = nrepl#fireplace_connection#open(port)
      let s:leiningen_repls[b:leiningen_root].connection = conn
      call s:register_connection(conn, b:leiningen_root)
      let s:leiningen_paths[b:leiningen_root] = conn.path()
    catch /^nREPL Connection Error:/
      if &verbose
        echohl WarningMSG
        echomsg v:exception
        echohl None
      endif
    endtry
  endif
endfunction

function! s:leiningen_init() abort

  if !exists('b:leiningen_root')
    let root = s:hunt(expand('%:p'), 'project.clj', '(\s*defproject')
    if root !=# ''
      let b:leiningen_root = root
    endif
  endif
  if !exists('b:leiningen_root')
    return
  endif

  let b:java_root = b:leiningen_root

  compiler lein

  if exists('classpath#from_vim')
    let s:leiningen_paths[b:leiningen_root] = classpath#split(classpath#from_vim(&path))
  endif
  call s:leiningen_connect()
endfunction

function! s:massage_quickfix() abort
  if &errorformat !~# 'fireplace$'
    return
  endif
  if has_key(s:leiningen_paths, getcwd())
    let path = s:leiningen_paths[getcwd()]
  else
    return
  endif
  let qflist = getqflist()
  for entry in qflist
    call extend(entry, s:qfmassage(get(entry, 'text', ''), path))
  endfor
  call setqflist(qflist, 'replace')
endfunction

augroup fireplace_leiningen
  autocmd!
  autocmd User FireplacePreConnect call s:leiningen_connect()
  autocmd FileType clojure call s:leiningen_init()
  autocmd QuickFixCmdPost make,cfile,cgetfile call s:massage_quickfix()
augroup END

" }}}1

" vim:set et sw=2:
