" autoload/nrepl/fireplace_connection.vim
" Maintainer:   Tim Pope <http://tpo.pe/>

if exists("g:autoloaded_nrepl_fireplace_connection") || &cp
  finish
endif
let g:autoloaded_nrepl_fireplace_connection = 1

let s:python_dir = fnamemodify(expand("<sfile>"), ':p:h:h:h') . '/python'

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '<SNR>\d\+_'),''))
endfunction

" Bencode {{{1

function! nrepl#fireplace_connection#bencode(value) abort
  if type(a:value) == type(0)
    return 'i'.a:value.'e'
  elseif type(a:value) == type('')
    return strlen(a:value).':'.a:value
  elseif type(a:value) == type([])
    return 'l'.join(map(copy(a:value),'nrepl#fireplace_connection#bencode(v:val)'),'').'e'
  elseif type(a:value) == type({})
    return 'd'.join(values(map(copy(a:value),'nrepl#fireplace_connection#bencode(v:key).nrepl#fireplace_connection#bencode(v:val)')),'').'e'
  else
    throw "Can't bencode ".string(a:value)
  endif
endfunction

" }}}1

function! s:shellesc(arg) abort
  if a:arg =~ '^[A-Za-z0-9_/.-]\+$'
    return a:arg
  elseif &shell =~# 'cmd'
    return '"'.substitute(substitute(a:arg, '"', '""""', 'g'), '%', '"%"', 'g').'"'
  else
    let escaped = shellescape(a:arg)
    if &shell =~# 'sh' && &shell !~# 'csh'
      return substitute(escaped, '\\\n', '\n', 'g')
    else
      return escaped
    endif
  endif
endfunction

if !exists('s:id')
  let s:vim_id = localtime()
  let s:id = 0
endif
function! s:id() abort
  let s:id += 1
  return 'fireplace-'.hostname().'-'.s:vim_id.'-'.s:id
endfunction

function! nrepl#fireplace_connection#prompt() abort
  return fireplace#input_host_port()
endfunction

function! nrepl#fireplace_connection#open(arg) abort
  if a:arg =~# '^\d\+$'
    let host = 'localhost'
    let port = a:arg
  elseif a:arg =~# ':\d\+$'
    let host = matchstr(a:arg, '.*\ze:')
    let port = matchstr(a:arg, ':\zs.*')
  else
    throw "nREPL: Couldn't find [host:]port in " . a:arg
  endif
  let client = deepcopy(s:nrepl)
  let client.host = host
  let client.port = port
  let client.session = client.process({'op': 'clone', 'session': 0})['new-session']
  let response = client.process({'op': 'eval', 'code':
        \ '(do (println "success") (symbol (str (System/getProperty "path.separator") (System/getProperty "java.class.path"))))'})
  let client._path = response.value[-1]
  if !has_key(response, 'out')
    unlet client.session
  endif
  return client
endfunction

function! s:nrepl_path() dict abort
  return split(self._path[1:-1], self._path[0])
endfunction

function! s:nrepl_process(payload) dict abort
  let combined = {'status': [], 'session': []}
  for response in self.call(a:payload)
    for key in keys(response)
      if key ==# 'id' || key ==# 'ns'
        let combined[key] = response[key]
      elseif key ==# 'value'
        let combined.value = extend(get(combined, 'value', []), [response.value])
      elseif key ==# 'status'
        for entry in response[key]
          if index(combined[key], entry) < 0
            call extend(combined[key], [entry])
          endif
        endfor
      elseif key ==# 'session'
        if index(combined[key], response[key]) < 0
          call extend(combined[key], [response[key]])
        endif
      elseif type(response[key]) == type('')
        let combined[key] = get(combined, key, '') . response[key]
      else
        let combined[key] = response[key]
      endif
    endfor
  endfor
  if index(combined.status, 'error') >= 0
    throw 'nREPL: ' . tr(combined.status[0], '-', ' ')
  endif
  return combined
endfunction

function! s:nrepl_eval(expr, ...) dict abort
  let payload = {"op": "eval"}
  let payload.code = a:expr
  let options = a:0 ? a:1 : {}
  if has_key(options, 'ns')
    let payload.ns = options.ns
  elseif has_key(self, 'ns')
    let payload.ns = self.ns
  endif
  if has_key(options, 'session')
    let payload.session = options.session
  endif
  if has_key(options, 'file_path')
    let payload.op = 'load-file'
    let payload['file-path'] = options.file_path
    let payload['file-name'] = fnamemodify(options.file_path, ':t')
    if has_key(payload, 'ns')
      let payload.file = "(in-ns '".payload.ns.") ".payload.code
      call remove(payload, 'ns')
    else
      let payload.file = payload.code
    endif
    call remove(payload, 'code')
  endif
  let response = self.process(payload)
  if has_key(response, 'ns') && !a:0
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && !empty(get(payload, 'session', 1))
    let response.stacktrace = s:extract_last_stacktrace(self)
  endif

  if has_key(response, 'value')
    let response.value = response.value[-1]
  endif
  return response
endfunction

function! s:extract_last_stacktrace(nrepl) abort
    let format_st = '(clojure.core/symbol (clojure.core/str "\n\b" (clojure.core/apply clojure.core/str (clojure.core/interleave (clojure.core/repeat "\n") (clojure.core/map clojure.core/str (.getStackTrace *e)))) "\n\b\n"))'
    let stacktrace = split(get(split(a:nrepl.process({'op': 'eval', 'code': '['.format_st.' *3 *2 *1]', 'session': a:nrepl.session}).value[0], "\n\b\n"), 1, ""), "\n")
    call a:nrepl.call({'op': 'eval', 'code': '(nth *1 1)', 'session': a:nrepl.session})
    call a:nrepl.call({'op': 'eval', 'code': '(nth *2 2)', 'session': a:nrepl.session})
    call a:nrepl.call({'op': 'eval', 'code': '(nth *3 3)', 'session': a:nrepl.session})
    return stacktrace
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:nrepl_command(args) dict abort
  return 'python'
        \ . ' ' . s:shellesc(s:python_dir.'/nrepl_fireplace.py')
        \ . ' ' . s:shellesc(self.host)
        \ . ' ' . s:shellesc(self.port)
        \ . ' ' . s:shellesc(s:keepalive)
        \ . ' ' . join(map(copy(a:args), 's:shellesc(v:val)'), ' ')
endfunction

function! s:nrepl_dispatch(...) dict abort
  let in = self.command(a:000)
  let out = system(in)
  if !v:shell_error
    return eval(out)
  endif
  throw 'nREPL: '.out
endfunction

function! s:nrepl_prepare(payload) dict abort
  let payload = copy(a:payload)
  if !has_key(payload, 'id')
    let payload.id = s:id()
  endif
  if empty(get(payload, 'session', 1))
    unlet payload.session
  elseif !has_key(self, 'session')
    if &verbose
      echohl WarningMSG
      echo "nREPL: server has bug preventing session support"
      echohl None
    endif
    unlet! payload.session
  elseif !has_key(payload, 'session')
    let payload.session = self.session
  endif
  return payload
endfunction

function! s:nrepl_call(payload) dict abort
  let payload = self.prepare(a:payload)
  return filter(self.dispatch('call', nrepl#fireplace_connection#bencode(payload)), 'v:val.id == payload.id')
endfunction

let s:nrepl = {
      \ 'command': s:function('s:nrepl_command'),
      \ 'dispatch': s:function('s:nrepl_dispatch'),
      \ 'prepare': s:function('s:nrepl_prepare'),
      \ 'call': s:function('s:nrepl_call'),
      \ 'eval': s:function('s:nrepl_eval'),
      \ 'path': s:function('s:nrepl_path'),
      \ 'process': s:function('s:nrepl_process')}

if !has('python') || $FIREPLACE_NO_IF_PYTHON
  finish
endif

if !exists('s:python')
  exe 'python sys.path.insert(0, "'.escape(s:python_dir, '\"').'")'
  let s:python = 1
  python import nrepl_fireplace
else
  python reload(nrepl_fireplace)
endif

python << EOF
import vim

def fireplace_let(var, value):
  return vim.command('let ' + var + ' = ' + nrepl_fireplace.vim_encode(value))

def fireplace_check():
  vim.eval('getchar(1)')

def fireplace_repl_dispatch(command, *args):
  try:
    fireplace_let('out', nrepl_fireplace.dispatch(vim.eval('self.host'), vim.eval('self.port'), fireplace_check, None, command, *args))
  except Exception, e:
    fireplace_let('err', str(e))
EOF

function! s:nrepl_dispatch(command, ...) dict abort
  python fireplace_repl_dispatch(vim.eval('a:command'), *vim.eval('a:000'))
  if !exists('err')
    return out
  endif
  throw 'nREPL Connection Error: '.err
endfunction

" vim:set et sw=2:
