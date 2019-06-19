" Location: autoload/fireplace/transport.vim
" Author: Tim Pope <http://tpo.pe/>

if exists('g:autoloaded_fireplace_transport')
  finish
endif
let g:autoloaded_fireplace_transport = 1

let s:python_dir = fnamemodify(expand("<sfile>"), ':p:h:h:h') . '/python'
if !exists('g:fireplace_python_executable')
  let g:fireplace_python_executable = executable('python3') ? 'python3' : 'python'
endif

if !exists('s:keepalive')
  let s:keepalive = tempname()
  call writefile([getpid()], s:keepalive)
endif

function! s:json_send(job, msg) abort
  if type(a:job) == v:t_number
    call chansend(a:job, json_encode(a:msg) . "\n")
  else
    call ch_sendexpr(a:job, a:msg)
  endif
endfunction

function! s:stop(job) abort
  if type(a:job) == v:t_int
    return jobstop(a:job)
  else
    return job_stop(a:job)
  endif
endfunction

function! s:wrap_nvim_callback(cb, buffer, job, msgs, _) abort
  let a:msgs[0] = a:buffer[0] . a:msgs[0]
  let a:buffer[0] = remove(a:msgs, -1)
  for msg in a:msgs
    call call(a:cb, [a:job, json_decode(msg)[1]])
  endfor
endfunction

function! s:json_start(command, out_cb, exit_cb) abort
  if exists('*job_start') || !exists('*jobstart')
    return job_start(a:command, {
          \ "in_mode": "json",
          \ "out_mode": "json",
          \ "out_cb": a:out_cb,
          \ "exit_cb": a:exit_cb,
          \ })
  else
    return jobstart(a:command, {
          \ "on_stdout": function('s:wrap_nvim_callback', [a:out_cb, ['']]),
          \ "on_exit": { job, status, type -> call(a:exit_cb, [job, status])},
          \ })
  endif
endfunction

function! s:json_callback(state, requests, job, msg) abort
  if type(a:msg) ==# v:t_list && len(a:msg) == 2
    if a:msg[0] ==# 'exception'
      let g:fireplace_last_python_exception = a:msg[1]
    elseif a:msg[0] ==# 'status'
      let a:state.status = a:msg[1]
    endif
  endif
  if type(a:msg) !=# v:t_dict || !has_key(a:msg, 'id')
    return
  endif
  if has_key(a:requests, get(a:msg, 'id'))
    call call(a:requests[a:msg.id], [a:msg])
    if index(get(a:msg, 'status', []), 'done') >= 0
      call remove(a:requests, a:msg.id)
    endif
  endif
endfunction

function! s:exit_callback(state, requests, job, status) abort
  let a:state.exit = a:status
endfunction

function! fireplace#transport#connect(arg) abort
  let arg = substitute(a:arg, '^nrepl://', '', '')
  if arg =~# '^\d\+$'
    let host = 'localhost'
    let port = a:arg
  elseif arg =~# '^[^:/@]\+:\d\+\%(/\|$\)'
    let host = matchstr(a:arg, '^[^:/@]\+')
    let port = matchstr(a:arg, ':\zs\d\+')
  else
    throw "Fireplace: invalid connection string " . string(arg)
  endif
  let command = [g:fireplace_python_executable,
        \ s:python_dir.'/nrepl_fireplace.py',
        \ host,
        \ port,
        \ s:keepalive,
        \ 'tunnel']
  let transport = deepcopy(s:nrepl_transport)
  let transport.state = {}
  let transport.requests = {}
  let cb_args = [transport.state, transport.requests]
  let transport.job = s:json_start(command, function('s:json_callback', cb_args), function('s:exit_callback', cb_args))
  while !has_key(transport.state, 'status') && transport.alive()
    sleep 20m
  endwhile
  if get(transport.state, 'status') is# ''
    return transport
  endif
  throw 'Fireplace: Connection Error: ' . get(transport.state, 'status', 'Failed to run command ' . join(command, ' '))
endfunction

function! s:transport_alive() dict abort
  return !has_key(self.state, 'exit')
endfunction

function! s:transport_close() dict abort
  if has_key(self, 'job')
    call s:stop(self.job)
  endif
  return self
endfunction

function! s:transport_message(msg, ...) dict abort
  if !a:0
    let msgs = []
    let self.requests[a:msg.id] = function('add', [msgs])
  elseif empty(a:1)
    let self.requests[a:msg.id] = 'len'
  else
    let self.requests[a:msg.id] = a:1
  endif
  call s:json_send(self.job, a:msg)
  if !exists('msgs')
    return v:null
  endif
  while has_key(self.requests, a:msg.id)
    sleep 20m
  endwhile
  return msgs
endfunction

let s:nrepl_transport = {
      \ 'alive': function('s:transport_alive'),
      \ 'close': function('s:transport_close'),
      \ 'message': function('s:transport_message')}
