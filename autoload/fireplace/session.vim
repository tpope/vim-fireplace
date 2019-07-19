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
  if a:0 > 1 && type(a:2) == v:t_func
    call add(session.callbacks, function(a:2, a:000[2:-1]))
  endif
  let session.transport = a:transport
  let session.id = a:transport.message({'op': 'clone', 'session': a:0 ? a:1 : ''}, v:t_dict)['new-session']
  let session.session = session.id
  let session.url = a:transport.url . '/#' . session.id
  let a:transport.sessions[session.id] = function('s:session_callback', [], session)
  return session
endfunction

function! s:session_callback(msg) dict abort
  if index(get(a:msg, 'status', []), 'session-closed') >= 0
    call filter(self, 'v:key !=# "id" && v:key !=# "session"')
  endif
  for Callback in self.callbacks
    try
      call call(Callback, [a:msg])
    catch
    endtry
  endfor
endfunction

function! s:session_close() dict abort
  if has_key(self, 'id')
    try
      call self.message({'op': 'close'}, '')
    catch
    finally
      call filter(self, 'v:key !=# "id" && v:key !=# "session"')
    endtry
  endif
  return self
endfunction

function! s:session_clone(...) dict abort
  let session = call('fireplace#session#for', [self.transport, self.id] + a:000)
  if has_key(self, 'ns')
    let session.ns = self.ns
  endif
  return session
endfunction

function! s:session_path() dict abort
  return self.transport._path
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

  let response = self.message(msg, v:t_dict)

  if has_key(response, 'ns') && empty(get(options, 'ns'))
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && get(msg, 'session', self.id) ==# self.id
    let response.stacktrace = call('s:session_stacktrace_lines', [], self)
  endif

  if has_key(response, 'value')
    let response.value = response.value[-1]
  endif

  if index(response.status, 'namespace-not-found') < 0
    return response
  endif
  throw 'Fireplace: namespace not found: ' . get(msg, 'ns', 'user')
endfunction

function! s:session_stacktrace_lines() dict abort
  let format_st =
        \ '(let [st (or (when (= "#''cljs.core/str" (str #''str))' .
        \               ' (.-stack *e))' .
        \             ' (.getStackTrace *e))]' .
        \  ' (symbol' .
        \    ' (if (string? st)' .
        \      ' st' .
        \      ' (let [parts (if (= "class [Ljava.lang.StackTraceElement;" (str (type st)))' .
        \                    ' (map str st)' .
        \                    ' (seq (amap st idx ret (str (aget st idx)))))]' .
        \        ' (apply str (interpose "\n" (cons *e parts)))))' .
        \    '))'
  let response = self.message({'op': 'eval', 'code': format_st, 'ns': 'user', 'session': ''}, v:t_dict)
  return split(response.value[0], "\n", 1)
endfunction

function! s:close_on_first_done(transport, msg) abort
  if index(get(a:msg, 'status', []), 'done') >= 0
    call a:transport.message({'op': 'close', 'session': a:msg.session}, '')
  endif
endfunction

function! s:session_message(msg, ...) dict abort
  if !has_key(self, 'id')
    throw 'Fireplace: session closed'
  endif
  let msg = a:msg
  if !has_key(msg, 'session')
    let msg = copy(msg)
    let msg.session = self.id
  elseif empty(msg.session) && msg.session isnot# v:none || msg.session is# v:true
    let session = self.clone(function('s:close_on_first_done', [self.transport]))
    let msg = copy(msg)
    let msg.session = session.id
  endif
  return call(self.transport.message, [msg] + a:000, self.transport)
endfunction

function! s:session_has_op(op) dict abort
  return self.transport.has_op(a:op)
endfunction

let s:session = {
      \ 'close': s:function('s:session_close'),
      \ 'clone': s:function('s:session_clone'),
      \ 'message': s:function('s:session_message'),
      \ 'eval': s:function('s:session_eval'),
      \ 'has_op': s:function('s:session_has_op'),
      \ 'path': s:function('s:session_path'),
      \ 'stacktrace_lines': s:function('s:session_stacktrace_lines')}
