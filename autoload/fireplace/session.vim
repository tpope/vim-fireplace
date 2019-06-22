" Location:     autoload/session/fireplace.vim

if exists("g:autoloaded_fireplace_session")
  finish
endif
let g:autoloaded_fireplace_session = 1

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '.*\zs<SNR>\d\+_'),''))
endfunction


function! fireplace#session#for(transport, ...) abort
  let session = copy(s:session)
  let session.callbacks = []
  if a:0 && type(a:1) == v:t_func
    call add(session.callbacks(function(a:1, a:000[1:-1])))
  endif
  let session.transport = a:transport
  let session.id = session.process({'op': 'clone', 'session': a:0 ? a:1 : ''})['new-session']
  let session.session = session.id
  let a:transport.sessions[session.id] = function('s:session_callback', [], session)
  return session
endfunction

function! s:session_callback(msg) dict abort
  if index(get(a:msg, 'status', []), 'session-closed') >= 0
    if has_key(self, 'session')
      call remove(self, 'session')
    endif
    if has_key(self, 'id')
      call remove(self, 'id')
    endif
  endif
  for Callback in self.callbacks
    try
      call call(Callback, [a:msg])
      exe &debug =~# 'throw' ? '' : 'catch'
    endtry
  endfor
endfunction

function! s:session_close() dict abort
  if has_key(self, 'id')
    try
      call self.message({'op': 'close'}, '')
    catch
    finally
      unlet self.id
      unlet self.session
    endtry
  endif
  return self
endfunction

function! s:session_clone(...) dict abort
  return call('fireplace#session#for', [self.transport, self.id] + a:000)
endfunction

function! s:session_path() dict abort
  return self.transport._path
endfunction

function! s:session_process(msg) dict abort
  let combined = self.message(a:msg, v:t_dict)
  if index(combined.status, 'error') < 0
    return combined
  endif
  let status = filter(copy(combined.status), 'v:val !=# "done" && v:val !=# "error"')
  throw 'nREPL: ' . tr(join(status, ', '), '-', ' ')
endfunction

function! s:session_eval(expr, ...) dict abort
  let msg = {"op": "eval"}
  let msg.code = a:expr
  let options = a:0 ? a:1 : {}

  for [k, v] in items(options)
    let msg[tr(k, '_', '-')] = v
  endfor

  if !has_key(msg, 'ns') && has_key(self, 'ns')
    let msg.ns = self.ns
  endif

  if !has_key(msg, 'id')
    let msg.id = fireplace#transport#id()
  endif

  try
    let response = self.process(msg)
  finally
    if !exists('response')
      let session = get(msg, 'session', self.id)
      if !empty(session)
        call self.message({'op': 'interrupt', 'session': session, 'interrupt-id': msg.id}, '')
      endif
      throw 'Clojure: Interrupt'
    endif
  endtry
  if has_key(response, 'ns') && empty(get(options, 'ns'))
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && get(msg, 'session', self.id) ==# self.id
    let response.stacktrace = s:extract_last_stacktrace(self)
  endif

  if has_key(response, 'value')
    let response.value = response.value[-1]
  endif

  return response
endfunction

function! s:process_stacktrace_entry(entry) abort
  if !has_key(a:entry, 'class')
    return ''
  endif
  let str = a:entry.class.'.'.a:entry.method
  if !empty(get(a:entry, 'file'))
    let str .= '('.a:entry.file.':'.a:entry.line.')'
  endif
  return str
endfunction

function! s:extract_last_stacktrace(session) abort
  if a:session.has_op('stacktrace')
    let stacktrace = a:session.message({'op': 'stacktrace'})
    if len(stacktrace) > 0 && has_key(stacktrace[0], 'stacktrace')
      let stacktrace = stacktrace[0].stacktrace
    endif

    call map(stacktrace, 's:process_stacktrace_entry(v:val)')
    call filter(stacktrace, '!empty(v:val)')
    if !empty(stacktrace)
      return stacktrace
    endif
  endif
  let format_st =
        \ '(let [st (or (when (= "#''cljs.core/str" (str #''str))' .
        \               ' (.-stack *e))' .
        \             ' (.getStackTrace *e))]' .
        \  ' (symbol' .
        \    ' (str "\n\b"' .
        \         ' (if (string? st)' .
        \           ' st' .
        \           ' (let [parts (if (= "class [Ljava.lang.StackTraceElement;" (str (type st)))' .
        \                         ' (map str st)' .
        \                         ' (seq (amap st idx ret (str (aget st idx)))))]' .
        \             ' (apply str (interleave (repeat "\n") parts))))' .
        \         ' "\n\b\n")))'
  let response = a:session.process({'op': 'eval', 'code': '['.format_st.' *3 *2 *1]', 'ns': 'user', 'session': a:session})
  try
    let stacktrace = split(get(split(response.value[0], "\n\b\n"), 1, ""), "\n")
  catch
    throw string(response)
  endtry
  call a:session.message({'op': 'eval', 'code': '(*1 1)', 'ns': 'user'})
  call a:session.message({'op': 'eval', 'code': '(*2 2)', 'ns': 'user'})
  call a:session.message({'op': 'eval', 'code': '(*3 3)', 'ns': 'user'})
  return stacktrace
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:session_prepare(msg) dict abort
  let msg = copy(a:msg)
  if !has_key(msg, 'id')
    let msg.id = fireplace#transport#id()
  endif
  if empty(get(msg, 'ns', 1))
    unlet msg.ns
  endif
  if empty(get(msg, 'session', 1))
    unlet msg.session
  elseif !has_key(msg, 'session')
    let msg.session = self.id
  endif
  return msg
endfunction

function! s:session_message(msg, ...) dict abort
  let msg = self.prepare(a:msg)
  return call(self.transport.message, [msg] + a:000, self.transport)
endfunction

function! s:session_has_op(op) dict abort
  return self.transport.has_op(a:op)
endfunction

let s:session = {
      \ 'close': s:function('s:session_close'),
      \ 'clone': s:function('s:session_clone'),
      \ 'prepare': s:function('s:session_prepare'),
      \ 'message': s:function('s:session_message'),
      \ 'eval': s:function('s:session_eval'),
      \ 'has_op': s:function('s:session_has_op'),
      \ 'path': s:function('s:session_path'),
      \ 'process': s:function('s:session_process')}
