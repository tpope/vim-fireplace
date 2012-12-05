" foreplay.vim - Clojure REPL tease
" Maintainer:   Tim Pope <http://tpo.pe>

if exists("g:loaded_foreplay") || v:version < 700 || &cp
  finish
endif
let g:loaded_foreplay = 1

" File type {{{1

augroup foreplay_file_type
  autocmd!
  autocmd BufNewFile,BufReadPost *.clj setfiletype clojure
  autocmd FileType clojure
        \ if expand('%:p') !~# '^zipfile:' |
        \   let &l:path = classpath#detect() |
        \ endif
augroup END

" }}}1
" Shell escaping {{{1

function! foreplay#shellesc(arg) abort
  if a:arg =~ '^[A-Za-z0-9_/.-]\+$'
    return a:arg
  elseif &shell =~# 'cmd'
    return '"'.substitute(substitute(a:arg, '"', '""', 'g'), '%', '"%"', 'g').'"'
  else
    let escaped = shellescape(a:arg)
    if &shell =~# 'sh' && &shell !~# 'csh'
      return substitute(escaped, '\\\n', '\n', 'g')
    else
      return escaped
    endif
  endif
endfunction

" }}}1
" Completion {{{1

function! foreplay#eval_complete(A, L, P) abort
  let prefix = matchstr(a:A, '\%(.* \|^\)\%(#\=[\[{('']\)*')
  let keyword = a:A[strlen(prefix) : -1]
  return sort(map(foreplay#omnicomplete(0, keyword), 'prefix . v:val.word'))
endfunction

function! foreplay#ns_complete(A, L, P) abort
  let matches = []
  for pattern in split(&path, ',')
    for dir in split(glob(pattern), "\n")
      if dir =~# '\.jar$' && executable('zipinfo')
        let files = split(system('zipinfo -1 '.shellescape(dir).' "*.clj"'), "\n")
        if v:shell_error
          let files = []
        endif
      else
        let files = split(glob(dir."/**/*.clj"), "\n")
        call map(files, 'v:val[strlen(dir)+1 : -1]')
      endif
      let matches += files
    endfor
  endfor
  return filter(map(matches, 's:tons(v:val)'), 'a:A ==# "" || a:A ==# v:val[0 : strlen(a:A)-1]')
endfunction

function! foreplay#omnicomplete(findstart, base) abort
  if a:findstart
    let line = getline('.')[0 : col('.')-2]
    return col('.') - strlen(matchstr(line, '\k\+$')) - 1
  else
    try
      let omnifier = '(fn [[k v]] (let [m (meta v)]' .
            \ ' {:word k :menu (pr-str (:arglists m (symbol ""))) :info (str "  " (:doc m)) :kind (if (:arglists m) "f" "v")}))'

      let ns = foreplay#ns()

      let [aliases, namespaces, maps] = foreplay#evalparse(
            \ '[(ns-aliases '.s:qsym(ns).') (all-ns) '.
            \ '(sort-by :word (map '.omnifier.' (ns-map '.s:qsym(ns).')))]')

      if a:base =~# '^[^/]*/[^/]*$'
        let ns = matchstr(a:base, '^.*\ze/')
        let prefix = ns . '/'
        let ns = get(aliases, ns, ns)
        let keyword = matchstr(a:base, '.*/\zs.*')
        let results = foreplay#evalparse(
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

augroup foreplay_completion
  autocmd!
  autocmd FileType clojure setlocal omnifunc=foreplay#omnicomplete
augroup END

" }}}1
" REPL client {{{1

let s:repl = {"requires": {}}

if !exists('s:repls')
  let s:repls = []
  let s:repl_paths = {}
endif

function! s:qsym(symbol)
  if a:symbol =~# '^[[:alnum:]?*!+/=<>.:-]\+$'
    return "'".a:symbol
  else
    return '(symbol "'.escape(a:symbol, '"').'")'
  endif
endfunction

function! s:repl.eval(expr, ns) dict abort
  try
    let result = self.connection.eval(a:expr, a:ns)
  catch /^\w\+: Connection/
    call filter(s:repl_paths, 'v:val isnot self')
    call filter(s:repls, 'v:val isnot self')
    throw v:exception
  endtry
  return result
endfunction

function! s:repl.require(lib) dict abort
  if a:lib !~# '^\%(user\)\=$' && !get(self.requires, a:lib, 0)
    let reload = has_key(self.requires, a:lib) ? ' :reload' : ''
    let self.requires[a:lib] = 0
    call self.eval('(doto '.s:qsym(a:lib).' (require'.reload.') the-ns)', 'user')
    let self.requires[a:lib] = 1
  endif
  return ''
endfunction

function! s:repl.includes_file(file) dict abort
  let file = substitute(a:file, '\C^zipfile:\(.*\)::', '\1/', '')
  for path in self.connection.path()
    if file[0 : len(path)-1] ==? path
      return 1
    endif
  endfor
endfunction

function! s:register_connection(conn, ...)
  call insert(s:repls, extend({'connection': a:conn}, deepcopy(s:repl)))
  if a:0 && a:1 !=# ''
    let s:repl_paths[a:1] = s:repls[0]
  endif
  return s:repls[0]
endfunction

" }}}1
" :Connect {{{1

command! -bar -complete=customlist,s:connect_complete -nargs=? ForeplayConnect :exe s:Connect(<q-args>)

function! foreplay#input_host_port()
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

function! s:protos()
  return map(split(globpath(&runtimepath, 'autoload/*/foreplay_connection.vim'), "\n"), 'fnamemodify(v:val, ":h:t")')
endfunction

function! s:connect_complete(A, L, P)
  let proto = matchstr(a:A, '\w\+\ze://')
  if proto ==# ''
    let options = map(s:protos(), 'v:val."://"')
  else
    let rest = matchstr(a:A, '://\zs.*')
    try
      let options = {proto}#foreplay_connection#complete(rest)
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

function! s:Connect(arg)
  if a:arg =~# '^\w\+://'
    let [proto, arg] = split(a:arg, '://')
  elseif a:arg !=# ''
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
    let arg = {proto}#foreplay_connection#prompt()
  endif
  try
    let connection = {proto}#foreplay_connection#open(arg)
  catch /.*/
    return 'echoerr '.string(v:exception)
  endtry
  if type(connection) !=# type({}) || empty(connection)
    return ''
  endif
  let client = s:register_connection(connection)
  echo 'Connected to '.proto.'://'.arg
  let path = exists('b:java_root') ? b:java_root : fnamemodify(expand('%'), ':p:s?.*\zs[\/]src[\/].*??')
  let root = input('Path to root of project: ', path, 'dir')
  if root !=# ''
    let s:repls[root] = client
  endif
  echo "\n"
  return ''
endfunction

augroup foreplay_connect
  autocmd!
  autocmd FileType clojure command! -bar -complete=customlist,s:connect_complete -nargs=? Connect :ForeplayConnect <args>
augroup END

" }}}1
" Java runner {{{1

if !exists('g:java_cmd')
  let g:java_cmd = exists('$JAVA_CMD') ? $JAVA_CMD : 'java'
endif

let s:oneoff = {}

let s:oneoff_pr  = tempname()
let s:oneoff_ex  = tempname()
let s:oneoff_in  = tempname()
let s:oneoff_out = tempname()
let s:oneoff_err = tempname()

function! s:oneoff.eval(expr, ns) dict abort
  if &verbose
    echohl WarningMSG
    echomsg "No REPL found. Running java clojure.main ..."
    echohl None
  endif
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
  let command = g:java_cmd.' -cp '.shellescape(self.classpath).' clojure.main -e ' .
        \ foreplay#shellesc(
        \   '(binding [*out* (java.io.FileWriter. "'.s:oneoff_out.'")' .
        \   '          *err* (java.io.FileWriter. "'.s:oneoff_err.'")]' .
        \   '  (try' .
        \   '    (require ''clojure.repl) '.ns.'(spit "'.s:oneoff_pr.'" (pr-str (eval (read-string (slurp "'.s:oneoff_in.'")))))' .
        \   '    (catch Exception e' .
        \   '      (spit *err* (.toString e))' .
        \   '      (spit "'.s:oneoff_ex.'" (class e))))' .
        \   '  nil)')
  let wtf = system(command)
  let pr  = join(readfile(s:oneoff_pr, 'b'), "\n")
  let out = join(readfile(s:oneoff_out, 'b'), "\n")
  let err = join(readfile(s:oneoff_err, 'b'), "\n")
  let ex  = join(readfile(s:oneoff_err, 'b'), "\n")
  if v:shell_error && ex ==# ''
    throw 'Error running Clojure: '.wtf
  else
    if err !=# ''
      echohl ErrorMSG
      echo substitute(err, '\n$', '', '')
      echohl None
    endif
    if out !=# ''
      echo substitute(out, "\n$", '', '')
    endif
    if v:shell_error
      throw 'Clojure: '.ex
    else
      return pr
    endif
  endif
endfunction

function! s:oneoff.require(symbol)
  return ''
endfunction

" }}}1
" Client {{{1

function! s:client() abort
  silent doautocmd User ForeplayPreConnect
  let buf = exists('s:input') ? s:input : '%'
  let root = simplify(fnamemodify(bufname(buf), ':p:s?[\/]$??'))
  let previous = ""
  while root !=# previous
    if has_key(s:repl_paths, root)
      return s:repl_paths[root]
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile
  return foreplay#local_client(1)
endfunction

function! foreplay#client() abort
  return s:client()
endfunction

function! foreplay#local_client(...)
  if !a:0
    silent doautocmd User ForeplayPreConnect
  endif
  let buf = exists('s:input') ? s:input : '%'
  for repl in s:repls
    if repl.includes_file(fnamemodify(bufname(buf), ':p'))
      return repl
    endif
  endfor
  let cp = classpath#from_vim(getbufvar(buf, '&path'))
  return extend({'classpath': cp}, s:oneoff)
endfunction

function! foreplay#eval(expr, ...) abort
  let c = s:client()
  if !a:0
    call c.require(foreplay#ns())
  endif
  return c.eval(a:expr, a:0 ? a:1 : foreplay#ns())
endfunction

function! foreplay#evalparse(expr) abort
  let body = foreplay#eval(
        \ '(symbol ((fn *vimify [x]' .
        \ '  (cond' .
        \ '    (map? x)     (str "{" (apply str (interpose ", " (map (fn [[k v]] (str (*vimify k) ": " (*vimify v))) x))) "}")' .
        \ '    (coll? x)    (str "[" (apply str (interpose ", " (map #(*vimify %) x))) "]")' .
        \ '    (number? x)  (pr-str x)' .
        \ '    (keyword? x) (pr-str (name x))' .
        \ '    :else        (pr-str (str x)))) '.a:expr.'))',
        \ a:0 ? a:1 : foreplay#ns())
  if body ==# ''
    return ''
  else
    return eval(body)
  endif
endfunction

" }}}1
" Eval {{{1

let foreplay#skip = 'synIDattr(synID(line("."),col("."),1),"name") =~? "comment\\|string\\|char"'

function! s:opfunc(type) abort
  let sel_save = &selection
  let cb_save = &clipboard
  let reg_save = @@
  try
    set selection=inclusive clipboard-=unnamed clipboard-=unnamedplus
    if a:type =~ '^\d\+$'
      silent exe 'normal! ^v'.a:type.'$hy'
    elseif a:type =~# '^.$'
      silent exe "normal! `<" . a:type . "`>y"
    elseif a:type ==# 'line'
      silent exe "normal! '[V']y"
    elseif a:type ==# 'block'
      silent exe "normal! `[\<C-V>`]y"
    elseif a:type ==# 'outer'
      call searchpair('(','',')', 'Wbcr', g:foreplay#skip)
      silent exe "normal! vaby"
    else
      silent exe "normal! `[v`]y"
    endif
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
    let @@ = matchstr(expr, '^\n\+').foreplay#eval(expr, foreplay#ns()).matchstr(expr, '\n\+$')
    if @@ !~# '^\n*$'
      normal! gvp
    endif
  catch /^Clojure:/
    return ''
  finally
    let @@ = reg_save
  endtry
endfunction

function! s:printop(type) abort
  try
    echo foreplay#eval(s:opfunc(a:type))
  catch /^Clojure:/
    return ''
  endtry
endfunction

function! s:editop(type) abort
  call feedkeys(&cedit . "\<Home>", 'n')
  let input = s:input(substitute(substitute(s:opfunc(a:type), "\s*;[^\n]*", '', 'g'), '\n\+\s*', ' ', 'g'))
  try
    if input !=# ''
      echo foreplay#eval(input)
    endif
  catch /^Clojure:/
    return ''
  endtry
endfunction

function! s:Eval(bang, line1, line2, count, args) abort
  if a:args !=# ''
    let expr = a:args
  else
    if a:count ==# 0
      normal! ^
      let line1 = searchpair('(','',')', 'bcrn', g:foreplay#skip)
      let line2 = searchpair('(','',')', 'n', g:foreplay#skip)
    else
      let line1 = a:line1
      let line2 = a:line2
    endif
    if !line1 || !line2
      return ''
    endif
    let expr = join(getline(line1, line2), "\n")
    if a:bang
      exe line1.','.line2.'delete _'
    endif
  endif
  try
    let result = foreplay#eval(expr)
    if a:bang
      if a:args !=# ''
        call append(a:line1, result)
        exe a:line1
      else
        call append(a:line1-1, result)
        exe a:line1-1
      endif
    else
      echo result
    endif
  catch /^Clojure:/
  endtry
  return ''
endfunction

" If we call input() directly inside a try, and the user opens the command
" line window and tries to switch out of it (such as with ctrl-w), Vim will
" crash when the command line window closes.  Adding an indirect function call
" works around this.
function! s:actually_input(...)
  return call(function('input'), a:000)
endfunction

function! s:input(default) abort
  if !exists('g:FOREPLAY_HISTORY')
    let g:FOREPLAY_HISTORY = []
  endif
  try
    let s:input = bufnr('%')
    let s:oldhist = s:histswap(g:FOREPLAY_HISTORY)
    return s:actually_input(foreplay#ns().'=> ', a:default, 'customlist,foreplay#eval_complete')
  finally
    unlet! s:input
    if exists('s:oldhist')
      let g:FOREPLAY_HISTORY = s:histswap(s:oldhist)
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
  if input ==# ''
    return ''
  else
    try
      echo foreplay#eval(input)
      return ''
    catch /^Clojure:/
      return ''
    catch
      return 'echoerr '.string(v:exception)
    endtry
  endif
endfunction

function! s:recall() abort
  try
    cnoremap <expr> ) <SID>inputclose()
    let input = s:input('(')
    if input =~# '^(\=$'
      return ''
    else
      return foreplay#eval(input)
    endif
  catch /^Clojure:/
    return ''
  finally
    silent! cunmap )
  endtry
endfunction

function! s:histswap(list)
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

nnoremap <silent> <Plug>ForeplacePrint  :<C-U>set opfunc=<SID>printop<CR>g@
xnoremap <silent> <Plug>ForeplacePrint  :<C-U>call <SID>printop(visualmode())<CR>

nnoremap <silent> <Plug>ForeplaceFilter :<C-U>set opfunc=<SID>filterop<CR>g@
xnoremap <silent> <Plug>ForeplaceFilter :<C-U>call <SID>filterop(visualmode())<CR>

nnoremap <silent> <Plug>ForeplaceEdit   :<C-U>set opfunc=<SID>editop<CR>g@
xnoremap <silent> <Plug>ForeplaceEdit   :<C-U>call <SID>editop(visualmode())<CR>

nnoremap          <Plug>ForeplacePrompt :exe <SID>inputeval()<CR>

noremap!          <Plug>ForeplaceRecall <C-R>=<SID>recall()<CR>

function! s:eval_setup() abort
  command! -buffer -bang -range=0 -nargs=? -complete=customlist,foreplay#eval_complete Eval :exe s:Eval(<bang>0, <line1>, <line2>, <count>, <q-args>)

  nmap <buffer> cp <Plug>ForeplacePrint
  xmap <buffer> cp <Plug>ForeplacePrint
  nmap <buffer> cpp <Plug>ForeplacePrintab

  nmap <buffer> c! <Plug>ForeplaceFilter
  xmap <buffer> c! <Plug>ForeplaceFilter
  nmap <buffer> c!! <Plug>ForeplaceFilterab

  nmap <buffer> cq <Plug>ForeplaceEdit
  nmap <buffer> cqq <Plug>ForeplaceEditab

  nmap <buffer> cqp <Plug>ForeplacePrompt
  exe 'nmap <buffer> cqc <Plug>ForeplacePrompt' . &cedit . 'i'

  map! <buffer> <C-R>( <Plug>ForeplaceRecall
endfunction

function! s:cmdwinenter()
  setlocal filetype=clojure
endfunction

function! s:cmdwinleave()
  setlocal filetype< omnifunc<
endfunction

augroup foreplay_eval
  autocmd!
  autocmd FileType clojure call s:eval_setup()
  autocmd CmdWinEnter @ if exists('s:input') | call s:cmdwinenter() | endif
  autocmd CmdWinLeave @ if exists('s:input') | call s:cmdwinleave() | endif
augroup END

" }}}1
" :Require {{{1

function! s:Require(bang, ns)
  let cmd = ('(require '.s:qsym(a:ns ==# '' ? foreplay#ns() : a:ns).' :reload'.(a:bang ? '-all' : '').')')
  echo cmd
  try
    call foreplay#eval(cmd)
    return ''
  catch /^Clojure:.*/
    return ''
  endtry
endfunction

augroup foreplay_require
  autocmd!
  autocmd FileType clojure command! -buffer -bar -bang -complete=customlist,foreplay#ns_complete -nargs=? Require :exe s:Require(<bang>0, <q-args>)
augroup END

" }}}1
" Go to source {{{1

function! foreplay#source(symbol) abort
  let c = foreplay#local_client()
  call c.require(foreplay#ns())
  let cmd =
        \ "  (when-let [v (resolve " . s:qsym(a:symbol) .')]' .
        \ '    (when-let [filepath (:file (meta v))]' .
        \ '      (when-let [url (.getResource (clojure.lang.RT/baseLoader) filepath)]' .
        \ '        (symbol (str (str "+" (:line (meta v))) " "' .
        \ '            (if (= "jar" (.getProtocol url))' .
        \ '              (str "zip" (.replaceFirst (.getFile url) "!/" "::"))' .
        \ '              (.getFile url)))))))'
  let result = get(split(c.eval(cmd, foreplay#ns()), "\n"), 0, '')
  return result ==# 'nil' ? '' : result
endfunction

function! s:Edit(cmd, keyword) abort
  if a:keyword =~# '^\k\+/$'
    let location = foreplay#findfile(a:keyword[0: -2])
  elseif a:keyword =~# '^\k\+\.[^/.]\+$'
    let location = foreplay#findfile(a:keyword)
  else
    let location = foreplay#source(a:keyword)
  endif
  if location !=# ''
    if matchstr(location, '^+\d\+ \zs.*') ==# expand('%:p') && a:cmd ==# 'edit'
      return matchstr(location, '\d\+')
    else
      return a:cmd.' '.location.'|let &l:path = '.string(&l:path)
    endif
  endif
  let v:errmsg = "Couldn't find source for ".a:keyword
  return 'echoerr v:errmsg'
endfunction

augroup foreplay_source
  autocmd!
  autocmd FileType clojure setlocal includeexpr=tr(v:fname,'.-','/_')
  autocmd FileType clojure setlocal suffixesadd=.clj,.java
  autocmd FileType clojure setlocal define=^\\s*(def\\w*
  autocmd FileType clojure command! -bar -buffer -nargs=1 -complete=customlist,foreplay#eval_complete Djump  :exe s:Edit('edit', <q-args>)
  autocmd FileType clojure command! -bar -buffer -nargs=1 -complete=customlist,foreplay#eval_complete Dsplit :exe s:Edit('split', <q-args>)
  autocmd FileType clojure nnoremap <silent><buffer> [<C-D>     :<C-U>exe <SID>Edit('edit', expand('<cword>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> ]<C-D>     :<C-U>exe <SID>Edit('edit', expand('<cword>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W><C-D> :<C-U>exe <SID>Edit('split', expand('<cword>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>d     :<C-U>exe <SID>Edit('split', expand('<cword>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>gd    :<C-U>exe <SID>Edit('tabedit', expand('<cword>'))<CR>
augroup END

" }}}1
" Go to file {{{1

function! foreplay#findfile(path) abort
  let c = foreplay#local_client()
  call c.require(foreplay#ns())

  let cmd =
        \ '(symbol' .
        \ '  (or' .
        \ '    (when-let [url (.getResource (clojure.lang.RT/baseLoader) %s)]' .
        \ '    (if (= "jar" (.getProtocol url))' .
        \ '      (str "zip" (.replaceFirst (.getFile url) "!/" "::"))' .
        \ '      (.getFile url)))' .
        \ '    ""))'

  let path = a:path

  if path !~# '[/.]' && path =~# '^\k\+$'
    let aliascmd = printf(cmd,
          \ '(if-let [ns ((ns-aliases *ns*) '.s:qsym(path).')]' .
          \ '  (str (.replace (.replace (str (ns-name ns)) "-" "_") "." "/") ".clj")' .
          \ '  "'.path.'.clj")')
    let result = get(split(c.eval(aliascmd, foreplay#ns()), "\n"), 0, '')
  else
    if path !~# '/'
      let path = tr(path, '.-', '/_')
    endif
    if path !~# '\.\w\+$'
      let path .= '.clj'
    endif

    let result = get(split(c.eval(printf(cmd, '"'.escape(path, '"').'"'), foreplay#ns()), "\n"), 0, '')

  endif
  if result ==# ''
    return findfile(path, &l:path)
  else
    return result
  endif
endfunction

function! s:GF(cmd, file) abort
  if a:file =~# '^[^/]*/[^/.]*$' && a:file =~# '^\k\+$'
    let [file, jump] = split(a:file, "/")
  else
    let file = a:file
  endif
  let file = foreplay#findfile(file)
  if file ==# ''
    let v:errmsg = "Couldn't find file for ".a:file
    return 'echoerr v:errmsg'
  endif
  return a:cmd .
        \ (exists('jump') ? ' +sil!\ djump\ ' . jump : '') .
        \ ' ' . fnameescape(file) .
        \ '| let &l:path = ' . string(&l:path)
endfunction

augroup foreplay_go_to_file
  autocmd!
  autocmd FileType clojure nnoremap <silent><buffer> gf         :<C-U>exe <SID>GF('edit', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>f     :<C-U>exe <SID>GF('split', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W><C-F> :<C-U>exe <SID>GF('split', expand('<cfile>'))<CR>
  autocmd FileType clojure nnoremap <silent><buffer> <C-W>gf    :<C-U>exe <SID>GF('tabedit', expand('<cfile>'))<CR>
augroup END

" }}}1
" Documentation {{{1

function! s:buffer_path(...) abort
  let buffer = a:0 ? a:1 : exists('s:input') ? s:input : '%'
  if getbufvar(buffer, '&buftype') =~# '^no'
    return ''
  endif
  let path = substitute(fnamemodify(bufname(buffer), ':p'), '\C^zipfile:\(.*\)::', '\1/', '')
  for dir in classpath#split(classpath#from_vim(getbufvar(buffer, '&path')))
    if dir !=# '' && path[0 : strlen(dir)-1] ==# dir
      return path[strlen(dir)+1:-1]
    endif
  endfor
  return ''
endfunction

function! s:tons(path) abort
  return tr(substitute(a:path, '\.\w\+$', '', ''), '\/_', '..-')
endfunction

function! foreplay#ns() abort
  return s:tons(s:buffer_path())
endfunction

function! s:Lookup(macro, arg) abort
  " doc is in clojure.core in older Clojure versions
  try
    call foreplay#eval("(eval (list (if (ns-resolve 'clojure.core '".a:macro.") '".a:macro." 'clojure.repl/".a:macro.") '".a:arg.'))')
  catch /^Clojure:/
  catch /.*/
    echohl ErrorMSG
    echo v:exception
    echohl None
  endtry
  return ''
endfunction

function! s:inputlist(label, entries)
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
  let matches = foreplay#evalparse('(apropos '.pattern.')')
  if empty(matches)
    return ''
  endif
  let choice = s:inputlist('Lookup docs for:', matches)
  if choice !=# ''
    return 'echo "\n"|Doc '.choice
  else
    return ''
  endif
endfunction

augroup foreplay_doc
  autocmd!
  autocmd FileType clojure nnoremap <buffer> K  :Doc <C-R><C-W><CR>
  autocmd FileType clojure nnoremap <buffer> [d :Source <C-R><C-W><CR>
  autocmd FileType clojure nnoremap <buffer> ]d :Source <C-R><C-W><CR>
  autocmd FileType clojure command! -buffer -nargs=1 FindDoc :exe s:Lookup('find-doc', printf('#"%s"', <q-args>))
  autocmd FileType clojure command! -buffer -bar -nargs=1 -complete=customlist,foreplay#eval_complete Doc     :exe s:Lookup('doc', <q-args>)
  autocmd FileType clojure command! -buffer -bar -nargs=1 -complete=customlist,foreplay#eval_complete Source  :exe s:Lookup('source', <q-args>)
  autocmd FileType clojure command! -buffer -nargs=1 -complete=customlist,foreplay#eval_complete Apropos :exe s:Apropos(<q-args>)
augroup END

" }}}1
" Leiningen {{{1

function! s:hunt(start, anchor) abort
  let root = simplify(fnamemodify(a:start, ':p:s?[\/]$??'))
  let previous = ""
  while root !=# previous
    if filereadable(root . '/' .a:anchor) && isdirectory(root . '/src')
      return root
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile
  return ''
endfunction

if !exists('s:leiningen_repl_ports')
  let s:leiningen_repl_ports = {}
endif

function! s:leiningen_connect()
  if !exists('b:leiningen_root')
    return
  endif
  let portfile = b:leiningen_root . '/target/repl-port'
  if getfsize(portfile) > 0 && getftime(portfile) !=# get(s:leiningen_repl_ports, b:leiningen_root, -1)
    let port = readfile(portfile, 'b', 1)[0]
    let s:leiningen_repl_ports[b:leiningen_root] = getftime(portfile)
    try
      call s:register_connection(nrepl#foreplay_connection#open(port), b:leiningen_root)
    catch /^nREPL: Connection/
      call delete(portfile)
    endtry
  endif
endfunction

function! s:leiningen_init() abort

  if !exists('b:leiningen_root')
    let root = s:hunt(expand('%:p'), 'project.clj')
    if root !=# ''
      let b:leiningen_root = root
    endif
  endif
  if !exists('b:leiningen_root')
    return
  endif

  let b:java_root = b:leiningen_root

  setlocal makeprg=lein efm=%+G

  call s:leiningen_connect()
endfunction

augroup foreplay_leiningen
  autocmd!
  autocmd User ForeplacePreConnect call s:leiningen_connect()
  autocmd FileType clojure call s:leiningen_init()
augroup END

" }}}1

" vim:set et sw=2:
