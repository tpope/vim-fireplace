" Location:     autoload/nrepl/fireplace_connection.vim

if exists("g:autoloaded_nrepl_fireplace_connection") || &cp
  finish
endif
let g:autoloaded_nrepl_fireplace_connection = 1

let s:python_dir = fnamemodify(expand("<sfile>"), ':p:h:h:h') . '/python'

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '.*\zs<SNR>\d\+_'),''))
endfunction

function! s:shellesc(arg) abort
  if a:arg =~ '^[A-Za-z0-9_/.-]\+$'
    return a:arg
  elseif &shell =~# 'cmd'
    throw 'Python interface not working. See :help python-dynamic'
  else
    let escaped = shellescape(a:arg)
    if &shell =~# 'sh' && &shell !~# 'csh'
      return substitute(escaped, '\\\n', '\n', 'g')
    else
      return escaped
    endif
  endif
endfunction

function! fireplace#nrepl_connection#prompt() abort
  return fireplace#input_host_port()
endfunction

function! fireplace#nrepl_connection#open(arg) abort
  if a:arg =~# '^\d\+$'
    let host = 'localhost'
    let port = a:arg
  elseif a:arg =~# ':\d\+$'
    let host = matchstr(a:arg, '.*\ze:')
    let port = matchstr(a:arg, '.*:\zs.*')
  else
    throw "nREPL: Couldn't find [host:]port in " . a:arg
  endif
  let transport = deepcopy(s:nrepl_transport)
  let transport.host = host
  let transport.port = port
  return fireplace#nrepl#for(transport)
endfunction

function! s:nrepl_transport_close() dict abort
  return self
endfunction

if !exists('s:keepalive')
  let s:keepalive = tempname()
  call writefile([getpid()], s:keepalive)
endif

if !exists('g:fireplace_python_executable')
  let g:fireplace_python_executable = executable('python3') ? 'python3' : 'python'
endif

function! s:nrepl_transport_command(cmd, args) dict abort
  return [g:fireplace_python_executable,
        \ s:python_dir.'/nrepl_fireplace.py',
        \ self.host,
        \ self.port,
        \ s:keepalive,
        \ a:cmd] + map(copy(a:args), 'json_encode(v:val)')
endfunction

function! s:nrepl_transport_dispatch(cmd, ...) dict abort
  let in = join(map(self.command(a:cmd, a:000), 's:shellesc(v:val)'), ' ')
  let out = system(in)
  if !v:shell_error
    return json_decode(out)
  endif
  let g:fireplace_last_python_exception = json_decode(out)
  throw 'Fireplace Python exception: ' . g:fireplace_last_python_exception.title
endfunction

function! s:nrepl_transport_message(msg, ...) dict abort
  if !a:0
    return self.dispatch('message', a:msg)
  elseif empty(a:1)
    call self.dispatch('message', a:msg)
    return v:null
  else
    let response = self.dispatch('message', a:msg)
    call map(response, 'fireplace#nrepl#callback(v:val, "synchronous", a:000)')
    return v:null
  endif
endfunction

let s:nrepl_transport = {
      \ 'close': s:function('s:nrepl_transport_close'),
      \ 'command': s:function('s:nrepl_transport_command'),
      \ 'dispatch': s:function('s:nrepl_transport_dispatch'),
      \ 'message': s:function('s:nrepl_transport_message')}

let s:python = has('pythonx') ? 'pyx' : has('python3') ? 'py3' : has('python') ? 'py' : ''
if empty(s:python) || $FIREPLACE_NO_IF_PYTHON
  finish
endif

if !exists('s:python_loaded')
  exe s:python 'sys.path.insert(0, "'.escape(s:python_dir, '\"').'")'
  let s:python_loaded = 1
  exe s:python 'import nrepl_fireplace'
else
  if s:python ==# 'py3' || s:python ==# 'pyx' && &g:pyxversion ==# 3
    exe s:python 'from importlib import reload'
  endif
  exe s:python 'reload(nrepl_fireplace)'
endif

" Syntax highlighting hack
exe s:python '<< EOF'
python = EOF = 0
python << EOF

import json
import vim
import sys

def fireplace_check():
  vim.eval('getchar(1)')

def fireplace_repl_dispatch(command, *args):
  try:
    return [nrepl_fireplace.dispatch(vim.eval('self.host'), int(vim.eval('self.port')), fireplace_check, None, command, *args), {}]
  except Exception as e:
    return ['', nrepl_fireplace.quickfix(*sys.exc_info())]
EOF

function! s:nrepl_transport_dispatch(command, ...) dict abort
  let [out, err] = call(s:python . 'eval', ["fireplace_repl_dispatch(vim.eval('a:command'), *json.loads(vim.eval('json_encode(a:000)')))"])
  if empty(err)
    return out
  endif
  let g:fireplace_last_python_exception = err
  throw 'Fireplace Python exception: ' . g:fireplace_last_python_exception.title
endfunction
