" Location: autoload/fireplace/transport.vim
" Author: Tim Pope <http://tpo.pe/>

if exists('g:autoloaded_fireplace_transport')
  finish
endif
let g:autoloaded_fireplace_transport = 1

let s:python_dir = fnamemodify(expand("<sfile>"), ':p:h:h:h') . '/pythonx'
if !exists('g:fireplace_python_executable')
  let g:fireplace_python_executable = exepath('python3') =~? '^$\|\<appinstallerpythonredirector\.exe$' && executable('python') ? 'python' : 'python3'
endif

if !exists('s:id')
  let s:vim_id = 'fireplace-' . hostname() . '-' . localtime()
  let s:id = 0
endif
function! fireplace#transport#id() abort
  let s:id += 1
  let sha = sha256(s:vim_id . '-' . s:id . '-' . reltimestr(reltime()))
  return printf('%s-%s-4%s-%s-%s', sha[0:7], sha[8:11], sha[13:15], sha[16:19], sha[20:31])
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
    let buf = ['']
    return jobstart(a:command, {
          \ "on_stdout": { job, data, type -> timer_start(0, { t -> s:wrap_nvim_callback(a:out_cb, buf, job, data, type) }) },
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
    for l:Callback in a:requests[a:msg.id].callbacks
      try
        call call(l:Callback, [a:msg])
      catch
      endtry
    endfor
    if index(get(a:msg, 'status', []), 'done') >= 0
      call remove(a:requests, a:msg.id)
    endif
  endif
  if has_key(a:sessions, get(a:msg, 'session'))
    try
      call call(a:sessions[a:msg.session], [a:msg])
    catch
    endtry
    if index(get(a:msg, 'status', []), 'session-closed') >= 0
      call remove(a:sessions, a:msg.session)
    endif
  endif
endfunction

function! s:exit_callback(url, state, requests, sessions, job, status) abort
  if has_key(s:urls, a:url)
    call remove(s:urls, a:url)
  endif
  let a:state.exit = a:status
endfunction

if !exists('s:urls')
  let s:urls = {}
endif

augroup fireplace_transport
  autocmd!
  autocmd VimLeave for s:dict in values(s:urls)
        \ |   call s:dict.transport.Close()
        \ | endfor
augroup END

function! fireplace#transport#connect(arg) abort
  let url = substitute(a:arg, '#.*', '', '')
  if url =~# '^\d\+$'
    let url = 'nrepl://localhost:' . url
  elseif url =~# '^[^:/@]\+\(:\d\+\)\=$'
    let url = 'nrepl://' . url
  elseif url !~# '^\a\+://'
    throw "Fireplace: invalid connection string " . string(a:arg)
  endif
  let url = substitute(url, '^\a\+://[^/]*\zs$', '/', '')
  let url = substitute(url, '^nrepl://[^/:]*\zs/', ':7888/', '')
  if has_key(s:urls, url)
    return s:urls[url].transport
  endif
  let scheme = matchstr(url, '^\a\+')
  if scheme ==# 'nrepl'
    let command = [g:fireplace_python_executable, s:python_dir.'/fireplace.py']
  elseif exists('g:fireplace_argv_' . scheme)
    let command = g:fireplace_argv_{scheme}
  else
    throw 'Fireplace: unsupported protocol ' . scheme
  endif
  let transport = deepcopy(s:transport)
  let transport.url = url
  let transport.state = {}
  let transport.sessions = {}
  let transport.requests = {}
  let cb_args = [url, transport.state, transport.requests, transport.sessions]
  let transport.job = s:json_start(command + [url], function('s:json_callback', cb_args), function('s:exit_callback', cb_args))
  while !has_key(transport.state, 'status') && transport.Alive()
    sleep 1m
  endwhile
  if get(transport.state, 'status') is# ''
    let s:urls[transport.url] = {'transport': transport}
    let transport.describe = transport.Message({'op': 'describe', 'verbose?': 1}, v:t_dict)
    if transport.HasOp('classpath')
      let response = transport.Message({'op': 'classpath', 'session': ''}, v:t_dict)
      if type(get(response, 'classpath')) == type([])
        let transport._path = response.classpath
      endif
    endif
    if !has_key(transport, '_path')
      let response = transport.Message({'op': 'eval', 'code':
            \ '(System/getProperty "path.separator") (or' .
            \ ' (System/getProperty "fake.class.path")' .
            \ ' (System/getProperty "java.class.path") "") ' .
            \ '(System/getProperty "user.dir") ' .
            \ "(require 'clojure.repl 'clojure.java.javadoc)"}, v:t_dict)
      let transport._path = split(eval(response.value[1]), response.value[0][1])
      let cwd = eval(response.value[2])
      for i in range(len(transport._path))
        if transport._path[i] !~# '^/\|^\a\+:'
          let transport._path[i] = cwd . matchstr(cwd, '[\/]') . transport._path[i]
        endif
      endfor
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
      call self.Message({'op': 'close', 'session': session}, '')
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

  if empty(get(request, 'id', 1))
    call s:json_send(self.job, request)
    return {}
  endif

  let args = copy(a:000)

  if len(args) && type(args[0]) == v:t_number
    let ret_type = remove(args, 0)
  endif

  let received = []
  let message = {'id': request.id}
  if has_key(request, 'session')
    let message.session = request.session
  endif
  let callbacks = [function('add', [received])]
  if len(args) && type(args[0]) ==# v:t_list
    call extend(callbacks, map(copy(args), 'function(v:val, args[1:-1])'))
  elseif len(args) && (type(args[0]) == v:t_func || type(args[0]) == v:t_string && len(args[0]))
    call add(callbacks, function(args[0], args[1:-1]))
  endif

  let self.requests[request.id] = {'callbacks': callbacks}
  if has_key(request, 'session')
    let self.requests[request.id].session = request.session
  endif
  call s:json_send(self.job, request)
  if !exists('ret_type')
    return message
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
  if ret_type is# v:t_list
    return received
  elseif ret_type is# v:t_dict
    return fireplace#transport#combine(received)
  elseif ret_type is# v:t_number
    return len(received)
  else
    return message
  endif
endfunction

function! fireplace#transport#interrupt(id) abort
  for [url, dict] in items(s:urls)
    if has_key(dict.transport.requests, a:id)
      let request = dict.transport.requests[a:id]
      if has_key(dict.transport, 'job') && has_key(request, 'session')
        call s:json_send(dict.transport.job, {'op': 'interrupt', 'id': fireplace#transport#id(), 'session': request.session, 'interrupt-id': a:id})
      endif
    endif
  endfor
endfunction

function! fireplace#transport#stdin(session_or_id, data) abort
  let str = type(a:data) == v:t_string ? a:data : nr2char(a:data)
  let id = a:session_or_id
  for [url, dict] in items(s:urls)
    if has_key(dict.transport, 'job') && has_key(dict.transport.sessions, id)
      call s:json_send(dict.transport.job, {'op': 'stdin', 'id': fireplace#transport#id(), 'session': id, 'stdin': str})
      return v:true
    elseif has_key(dict.transport, 'job') && has_key(dict.transport.requests, id)
      call s:json_send(dict.transport.job, {'op': 'stdin', 'id': fireplace#transport#id(), 'session': dict.transport.requests[id].session, 'stdin': str})
      return v:true
    endif
  endfor
  return v:false
endfunction

function! s:done(id) abort
  for [url, dict] in items(s:urls)
    if has_key(dict.transport, 'job') && has_key(dict.transport.requests, a:id)
      return v:false
    endif
  endfor
  return v:true
endfunction

function! fireplace#transport#wait(id, ...) abort
  let max = a:0 ? a:1 : -1
  let ms = 0
  while !s:done(a:id)
    if ms == max
      return v:false
    endif
    let ms += 1
    if exists('*wait')
      call wait(1, { -> v:false })
    else
      sleep 1m
    endif
  endwhile
  return v:true
endfunction

let s:transport = {
      \ 'Alive': function('s:transport_alive'),
      \ 'Clone': function('s:transport_clone'),
      \ 'Close': function('s:transport_close'),
      \ 'HasOp': function('s:transport_has_op'),
      \ 'Message': function('s:transport_message'),
      \ 'alive': function('s:transport_alive'),
      \ 'clone': function('s:transport_clone'),
      \ 'close': function('s:transport_close'),
      \ 'has_op': function('s:transport_has_op'),
      \ 'message': function('s:transport_message')}
