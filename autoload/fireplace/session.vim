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
  let session.id = a:transport.Message({'op': 'clone', 'session': a:0 ? a:1 : ''}, v:t_dict)['new-session']
  let session.session = session.id
  let session.url = a:transport.url . '#' . session.id
  let a:transport.sessions[session.id] = function('s:session_callback', [], session)
  return session
endfunction

function! s:session_callback(msg) dict abort
  if index(get(a:msg, 'status', []), 'session-closed') >= 0
    call filter(self, 'v:key !=# "id" && v:key !=# "session"')
  endif
  for l:Callback in self.callbacks
    try
      call call(Callback, [a:msg])
    catch
    endtry
  endfor
endfunction

function! s:session_close() dict abort
  if has_key(self, 'id')
    try
      call self.Message({'op': 'close'}, '')
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

function! s:close_on_first_done(transport, msg) abort
  if index(get(a:msg, 'status', []), 'done') >= 0
    call a:transport.Message({'op': 'close', 'session': a:msg.session}, '')
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
  elseif empty(msg.session) && msg.session isnot# v:null || msg.session is# v:true
    let session = self.Clone(function('s:close_on_first_done', [self.transport]))
    let msg = copy(msg)
    let msg.session = session.id
  endif
  return call(self.transport.message, [msg] + a:000, self.transport)
endfunction

function! s:session_has_op(op) dict abort
  return self.transport.HasOp(a:op)
endfunction

let s:session = {
      \ 'Close': s:function('s:session_close'),
      \ 'Clone': s:function('s:session_clone'),
      \ 'HasOp': s:function('s:session_has_op'),
      \ 'Message': s:function('s:session_message'),
      \ 'Path': s:function('s:session_path'),
      \ 'close': s:function('s:session_close'),
      \ 'clone': s:function('s:session_clone'),
      \ 'has_op': s:function('s:session_has_op'),
      \ 'message': s:function('s:session_message'),
      \ 'path': s:function('s:session_path')}
