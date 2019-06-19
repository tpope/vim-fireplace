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

if !exists('s:id')
  let s:vim_id = localtime()
  let s:id = 0
endif
function! fireplace#transport#id() abort
  let s:id += 1
  return 'fireplace-'.hostname().'-'.s:vim_id.'-'.s:id
endfunction

function! fireplace#transport#combine(responses) abort
  if type(a:responses) == type({})
    return a:responses
  endif
  let combined = {'status': [], 'session': [], 'value': ['']}
  for response in a:responses
    for key in keys(response)
      if key ==# 'id'
        let combined[key] = response[key]
      elseif key ==# 'ns'
        let combined[key] = response[key]
        if !has_key(response, 'value')
          call add(combined.value, '')
        endif
      elseif key ==# 'value'
        let combined.value[-1] .= response.value
        if has_key(response, 'ns')
          call add(combined.value, '')
        endif
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
  call filter(combined.value, 'len(v:val)')
  if empty(combined.value)
    call remove(combined, 'value')
  endif
  return combined
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

function! s:transport_message(request, ...) dict abort
  let request = copy(a:request)
  if empty(get(request, 'id'))
    let request.id = fireplace#transport#id()
  endif
  if empty(get(request, 'session', 1))
    unlet request.session
  endif
  if empty(get(request, 'ns', 1))
    unlet request.ns
  endif

  if !a:0 || type(a:1) == v:t_number
    let msgs = []
    let self.requests[request.id] = function('add', [msgs])
  elseif empty(a:1)
    let self.requests[request.id] = function('len')
  else
    let self.requests[request.id] = function(a:1, a:000[1:-1])
  endif
  call s:json_send(self.job, request)
  if !exists('msgs')
    return v:null
  endif
  while has_key(self.requests, request.id)
    sleep 20m
  endwhile
  if !a:0 || a:1 is# v:t_list
    return msgs
  elseif a:1 is# v:t_dict
    return fireplace#transport#combine(msgs)
  else
    return v:null
  endif
endfunction

let s:nrepl_transport = {
      \ 'alive': function('s:transport_alive'),
      \ 'close': function('s:transport_close'),
      \ 'message': function('s:transport_message')}
