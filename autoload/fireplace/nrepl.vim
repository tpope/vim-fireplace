" Location:     autoload/nrepl/fireplace.vim

if exists("g:autoloaded_fireplace_nrepl")
  finish
endif
let g:autoloaded_fireplace_nrepl = 1

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '.*\zs<SNR>\d\+_'),''))
endfunction

if !exists('s:id')
  let s:vim_id = localtime()
  let s:id = 0
endif
function! fireplace#nrepl#next_id() abort
  let s:id += 1
  return 'fireplace-'.hostname().'-'.s:vim_id.'-'.s:id
endfunction

if !exists('g:fireplace_nrepl_sessions')
  let g:fireplace_nrepl_sessions = {}
endif

augroup fireplace_nrepl_connection
  autocmd!
  autocmd VimLeave * for s:session in values(g:fireplace_nrepl_sessions)
        \ |   call s:session.close()
        \ | endfor
augroup END

function! fireplace#nrepl#for(transport) abort
  let client = copy(s:nrepl)
  let client.transport = a:transport
  let client.session = client.process({'op': 'clone', 'session': 0})['new-session']
  let client.describe = client.process({'op': 'describe', 'verbose?': 1})
  if get(client.describe.versions.nrepl, 'major', -1) == 0 &&
        \ client.describe.versions.nrepl.minor < 2
    throw 'nREPL: 0.2.0 or higher required'
  endif
  " Handle boot, which sets a fake.class.path entry
  let response = client.process({'op': 'eval', 'code':
        \ '[(System/getProperty "path.separator") (System/getProperty "fake.class.path")]', 'session': ''})
  let cpath = response.value[-1][5:-2]
  if cpath !=# 'nil'
    let cpath = eval(cpath)
    if !empty(cpath)
      let client._path = split(cpath, response.value[-1][2])
    endif
  endif
  if !has_key(client, '_path') && client.has_op('classpath')
    let response = client.message({'op': 'classpath'})[0]
    if type(get(response, 'classpath')) == type([])
      let client._path = response.classpath
    endif
  endif
  if !has_key(client, '_path')
    let response = client.process({'op': 'eval', 'code':
          \ '[(System/getProperty "path.separator") (System/getProperty "java.class.path")]', 'session': ''})
    let client._path = split(eval(response.value[-1][5:-2]), response.value[-1][2])
  endif
  let g:fireplace_nrepl_sessions[client.session] = client
  return client
endfunction

function! s:nrepl_close() dict abort
  if has_key(self, 'session')
    try
      unlet! g:fireplace_nrepl_sessions[self.session]
      call self.message({'op': 'close'}, 'ignore')
    catch
    finally
      unlet self.session
    endtry
  endif
  call self.transport.close()
  return self
endfunction

function! s:nrepl_clone() dict abort
  let client = copy(self)
  if has_key(self, 'session')
    let client.session = client.process({'op': 'clone'})['new-session']
    let g:fireplace_nrepl_sessions[client.session] = client
  endif
  return client
endfunction

function! s:nrepl_path() dict abort
  return self._path
endfunction

function! fireplace#nrepl#combine(responses)
  let combined = {'status': [], 'session': []}
  for response in a:responses
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
  return combined
endfunction

function! s:nrepl_process(msg) dict abort
  let combined = fireplace#nrepl#combine(self.message(a:msg))
  if index(combined.status, 'error') < 0
    return combined
  endif
  throw 'nREPL: ' . tr(combined.status[0], '-', ' ')
endfunction

function! s:nrepl_eval(expr, ...) dict abort
  let msg = {"op": "eval"}
  let msg.code = a:expr
  let options = a:0 ? a:1 : {}
  if has_key(options, 'ns')
    let msg.ns = options.ns
  elseif has_key(self, 'ns')
    let msg.ns = self.ns
  endif
  if has_key(options, 'session')
    let msg.session = options.session
  endif
  if has_key(options, 'id')
    let msg.id = options.id
  else
    let msg.id = fireplace#nrepl#next_id()
  endif
  if has_key(options, 'file_path')
    let msg.op = 'load-file'
    let msg['file-path'] = options.file_path
    let msg['file-name'] = fnamemodify(options.file_path, ':t')
    if has_key(msg, 'ns')
      let msg.file = "(in-ns '".msg.ns.") ".msg.code
      call remove(msg, 'ns')
    else
      let msg.file = msg.code
    endif
    call remove(msg, 'code')
  endif
  try
    let response = self.process(msg)
  finally
    if !exists('response')
      let session = get(msg, 'session', self.session)
      if !empty(session)
        call self.message({'op': 'interrupt', 'session': session, 'interrupt-id': msg.id}, 'ignore')
      endif
      throw 'Clojure: Interrupt'
    endif
  endtry
  if has_key(response, 'ns') && empty(get(options, 'ns'))
    let self.ns = response.ns
  endif

  if has_key(response, 'ex') && !empty(get(msg, 'session', 1))
    let response.stacktrace = s:extract_last_stacktrace(self, get(msg, 'session', self.session))
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

function! s:extract_last_stacktrace(nrepl, session) abort
  if a:nrepl.has_op('stacktrace')
    let stacktrace = a:nrepl.message({'op': 'stacktrace', 'session': a:session})
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
  let response = a:nrepl.process({'op': 'eval', 'code': '['.format_st.' *3 *2 *1]', 'ns': 'user', 'session': a:session})
  try
    let stacktrace = split(get(split(response.value[0], "\n\b\n"), 1, ""), "\n")
  catch
    throw string(response)
  endtry
  call a:nrepl.message({'op': 'eval', 'code': '(*1 1)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*2 2)', 'ns': 'user', 'session': a:session})
  call a:nrepl.message({'op': 'eval', 'code': '(*3 3)', 'ns': 'user', 'session': a:session})
  return stacktrace
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:nrepl_prepare(msg) dict abort
  let msg = copy(a:msg)
  if !has_key(msg, 'id')
    let msg.id = fireplace#nrepl#next_id()
  endif
  if empty(get(msg, 'ns', 1))
    unlet msg.ns
  endif
  if empty(get(msg, 'session', 1))
    unlet msg.session
  elseif !has_key(msg, 'session')
    let msg.session = self.session
  endif
  return msg
endfunction

function! fireplace#nrepl#callback(body, type, callback) abort
  try
    let response = {'body': a:body, 'type': a:type}
    if has_key(g:fireplace_nrepl_sessions, get(a:body, 'session'))
      let response.session = g:fireplace_nrepl_sessions[a:body.session]
    endif
    call call(a:callback[0], [response] + a:callback[1:-1])
  catch
  endtry
endfunction

function! s:nrepl_call(msg, ...) dict abort
  let terms = a:0 ? a:1 : ['done']
  let sels = a:0 > 1 ? a:2 : {}
  return call(self.transport.call, [a:msg, terms, sels] + a:000[2:-1], self.transport)
endfunction

function! s:nrepl_message(msg, ...) dict abort
  let msg = self.prepare(a:msg)
  let sel = {'id': msg.id}
  return call(self.call, [msg, ['done'], sel] + a:000, self)
endfunction

function! s:nrepl_has_op(op) dict abort
  return has_key(self.describe.ops, a:op)
endfunction

let s:nrepl = {
      \ 'close': s:function('s:nrepl_close'),
      \ 'clone': s:function('s:nrepl_clone'),
      \ 'prepare': s:function('s:nrepl_prepare'),
      \ 'call': s:function('s:nrepl_call'),
      \ 'message': s:function('s:nrepl_message'),
      \ 'eval': s:function('s:nrepl_eval'),
      \ 'has_op': s:function('s:nrepl_has_op'),
      \ 'path': s:function('s:nrepl_path'),
      \ 'process': s:function('s:nrepl_process')}
