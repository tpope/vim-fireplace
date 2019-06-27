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

function! s:json_send(job, msg) abort
  if type(a:job) == v:t_number
    call chansend(a:job, json_encode(a:msg) . "\n")
  else
    call ch_sendexpr(a:job, a:msg)
  endif
endfunction

function! s:close(job) abort
  if type(a:job) == v:t_number
    return chanclose(a:job, 'stdin')
  else
    return ch_close_in(a:job)
  endif
endfunction

function! s:stop(job) abort
  if type(a:job) == v:t_number
    return jobstop(a:job)
  else
    call ch_close_in(a:job)
    return job_stop(a:job, 'kill')
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

function! s:json_callback(url, state, requests, sessions, job, msg) abort
  if type(a:msg) ==# v:t_list && len(a:msg) == 2
    if a:msg[0] ==# 'exception'
      let g:fireplace_last_python_exception = a:msg[1]
    elseif a:msg[0] ==# 'status'
      let a:state.status = a:msg[1]
    endif
  endif
  if type(a:msg) !=# v:t_dict
    return
  endif
  if has_key(a:msg, 'new-session') && !has_key(a:sessions, a:msg['new-session'])
    let a:sessions[a:msg['new-session']] = 'len'
  endif
  if has_key(a:requests, get(a:msg, 'id'))
    try
      call call(a:requests[a:msg.id], [a:msg])
    catch
    endtry
    if index(get(a:msg, 'status', []), 'done') >= 0
      call remove(a:requests, a:msg.id)
    endif
  endif
  if has_key(a:sessions, get(a:msg, 'session'))
    call call(a:sessions[a:msg.session], [a:msg])
    if index(get(a:msg, 'status', []), 'session-closed') >= 0
      call remove(a:sessions, a:msg.session)
    endif
  endif
endfunction

function! s:exit_callback(url, state, requests, sessions, job, status) abort
  call remove(s:urls, a:url)
  let a:state.exit = a:status
endfunction

if !exists('s:urls')
  let s:urls = {}
endif

augroup fireplace_transport
  autocmd!
  autocmd VimLeave for s:dict in values(s:urls)
        \ |   call s:dict.transport.close()
        \ | endfor
augroup END

function! fireplace#transport#connect(arg) abort
  let arg = substitute(a:arg, '^nrepl://', '', '')
  if arg =~# '^\d\+$'
    let host = 'localhost'
    let port = arg
  elseif arg =~# '^[^:/@]\+:\d\+\%(/\|$\)'
    let host = matchstr(a:arg, '^[^:/@]\+')
    let port = matchstr(a:arg, ':\zs\d\+')
  else
    throw "Fireplace: invalid connection string " . string(a:arg)
  endif
  let url = 'nrepl://' . host . ':' . port
  if has_key(s:urls, url)
    return s:urls[url].transport
  endif
  let command = [g:fireplace_python_executable,
        \ s:python_dir.'/nrepl_fireplace.py',
        \ host,
        \ port,
        \ s:keepalive,
        \ 'tunnel']
  let transport = deepcopy(s:transport)
  let transport.url = url
  let transport.state = {}
  let transport.sessions = {}
  let transport.requests = {}
  let cb_args = [url, transport.state, transport.requests, transport.sessions]
  let transport.job = s:json_start(command, function('s:json_callback', cb_args), function('s:exit_callback', cb_args))
  while !has_key(transport.state, 'status') && transport.alive()
    sleep 1m
  endwhile
  if get(transport.state, 'status') is# ''
    let s:urls[transport.url] = {'transport': transport}
    let transport.describe = transport.message({'op': 'describe', 'verbose?': 1}, v:t_dict)
    if transport.has_op('classpath')
      let response = transport.message({'op': 'classpath', 'session': ''})[0]
      if type(get(response, 'classpath')) == type([])
        let transport._path = response.classpath
      endif
    endif
    if !has_key(transport, '_path')
      let response = transport.message({'op': 'eval', 'code':
            \ '[(System/getProperty "path.separator") (or' .
            \ ' (System/getProperty "fake.class.path")' .
            \ ' (System/getProperty "java.class.path") "")]'}, v:t_dict)
      let transport._path = split(eval(response.value[-1][5:-2]), response.value[-1][2])
    endif
    return transport
  endif
  throw 'Fireplace: Connection Error: ' . get(transport.state, 'status', 'Failed to run command ' . join(command, ' '))
endfunction

function! s:transport_alive() dict abort
  return !has_key(self.state, 'exit')
endfunction

function! s:transport_clone(...) dict abort
  return call('fireplace#session#for', [self, ''] + a:000)
endfunction

function! s:transport_close() dict abort
  if has_key(self, 'job')
    for session in keys(self.sessions)
      call self.message({'op': 'close', 'session': session}, '')
      call remove(self.sessions, session)
    endfor
    call s:close(self.job)
    for i in range(50)
      if !has_key(s:urls, self.url)
        return self
      endif
      sleep 1m
    endfor
    call s:stop(self.job)
  endif
  return self
endfunction

function! s:transport_has_op(op) dict abort
  return has_key(self.describe.ops, a:op)
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
    return request.id
  endif
  try
    while has_key(self.requests, request.id)
      sleep 1m
    endwhile
  finally
    if has_key(self.requests, request.id) && has_key(request, 'session')
      call s:json_send(self.job, {'op': 'interrupt', 'id': fireplace#transport#id(), 'session': request.session, 'interrupt-id': request.id})
    endif
  endtry
  if !a:0 || a:1 is# v:t_list
    return msgs
  elseif a:1 is# v:t_dict
    return fireplace#transport#combine(msgs)
  else
    return v:null
  endif
endfunction

let s:transport = {
      \ 'alive': function('s:transport_alive'),
      \ 'clone': function('s:transport_clone'),
      \ 'close': function('s:transport_close'),
      \ 'has_op': function('s:transport_has_op'),
      \ 'message': function('s:transport_message')}
