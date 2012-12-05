" nrepl/foreplay_connection.vim
" Maintainer:   Tim Pope <http://tpo.pe/>

if exists("g:autoloaded_nrepl_foreplay_connection") || &cp
  finish
endif
let g:autoloaded_nrepl_foreplay_connection = 1

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '<SNR>\d\+_'),''))
endfunction

" Bencode {{{1

function! nrepl#foreplay_connection#bencode(value) abort
  if type(a:value) == type(0)
    return 'i'.a:value.'e'
  elseif type(a:value) == type('')
    return strlen(a:value).':'.a:value
  elseif type(a:value) == type([])
    return 'l'.join(map(a:value,'nrepl#foreplay_connection#bencode(v:val)'),'').'e'
  elseif type(a:value) == type({})
    return 'd'.join(values(map(a:value,'nrepl#foreplay_connection#bencode(v:key).nrepl#foreplay_connection#bencode(v:val)')),'').'e'
  else
    throw "Can't bencode ".string(a:value)
  endif
endfunction

function! nrepl#foreplay_connection#bdecode(value) abort
  return s:bdecode({'pos': 0, 'value': a:value})
endfunction

function! s:bdecode(state) abort
  let value = a:state.value
  if value[a:state.pos] =~# '\d'
    let pos = a:state.pos
    let length = matchstr(value[pos : -1], '^\d\+')
    let a:state.pos += strlen(length) + length + 1
    return value[pos+strlen(length)+1 : pos+strlen(length)+length]
  elseif value[a:state.pos] ==# 'i'
    let int = matchstr(value[a:state.pos+1:-1], '[^e]*')
    let a:state.pos += 2 + strlen(int)
    return str2nr(int)
  elseif value[a:state.pos] ==# 'l'
    let values = []
    let a:state.pos += 1
    while value[a:state.pos] !=# 'e' && value[a:state.pos] !=# ''
      call add(values, s:bdecode(a:state))
    endwhile
    let a:state.pos += 1
    return values
  elseif value[a:state.pos] ==# 'd'
    let values = {}
    let a:state.pos += 1
    while value[a:state.pos] !=# 'e' && value[a:state.pos] !=# ''
      let key = s:bdecode(a:state)
      let values[key] = s:bdecode(a:state)
    endwhile
    let a:state.pos += 1
    return values
  else
    throw 'bencode parse error: '.string(a:state)
  endif
endfunction

" }}}1

function! s:shellesc(arg) abort
  if a:arg =~ '^[A-Za-z0-9_/.-]\+$'
    return a:arg
  elseif &shell =~# 'cmd'
    return '"'.substitute(substitute(a:arg, '"', '""', 'g'), '%', '"%"', 'g').'"'
  else
    let escaped = shellescape(a:arg)
    if &shell =~# 'sh' && &shell !~# 'csh'
      return substitute(escaped, '\\\n', '\n', 'g')
    else
      return escaped
    endif
  endif
endfunction

function! nrepl#foreplay_connection#prompt() abort
  return foreplay#input_host_port()
endfunction

function! nrepl#foreplay_connection#open(arg) abort
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
  let client._path = client.eval('(symbol (str (System/getProperty "path.separator") (System/getProperty "java.class.path")))')
  return client
endfunction

function! s:nrepl_path() dict abort
  return split(self._path[1:-1], self._path[0])
endfunction

function! s:nrepl_process(payload) dict abort
  let parsed = self.call(a:payload)
  let result = {}
  for packet in parsed
    if has_key(packet, 'out')
      echo substitute(packet.out, '\n$', '', '')
    endif
    if has_key(packet, 'err')
      echohl ErrorMSG
      echo substitute(packet.err, '\n$', '', '')
      echohl NONE
    endif
    if has_key(packet, 'status') && index(packet.status, 'error') >= 0
      throw 'nREPL: ' . tr(packet.status[0], '-', ' ')
    endif
    if has_key(packet, 'ex') || has_key(packet, 'value')
      let result = packet
    endif
  endfor
  return result
endfunction

function! s:nrepl_eval(expr, ...) dict abort
  let payload = {"op": "eval", "code": a:expr}
  if a:0
    let payload.ns = a:1
  elseif has_key(self, 'ns')
    let payload.ns = self.ns
  endif
  let packet = self.process(payload)
  if has_key(packet, 'value')
    if !a:0
      let self.ns = packet.ns
    endif
    return packet.value
  elseif has_key(packet, 'ex')
    let err = 'Clojure: '.packet.ex
  else
    let err = 'nREPL: '.string(packet)
  endif
  throw err
endfunction

function! s:nrepl_call(payload) dict abort
  let in = 'ruby -rsocket -e '.s:shellesc(
        \ 'begin;' .
        \ 'TCPSocket.open(%(' . self.host . '), ' . self.port . ') {|s|' .
        \ 's.write(ARGV.first); loop {' .
        \ 'body = s.readpartial(8192); print body;' .
        \ 'break if body.include?(%(6:statusl4:done)) }};' .
        \ 'rescue; abort $!.to_s;' .
        \ 'end') . ' ' .
        \ s:shellesc(nrepl#foreplay_connection#bencode(a:payload))
  let out = system(in)
  if !v:shell_error
    return nrepl#foreplay_connection#bdecode('l'.out.'e')
  endif
  throw 'nREPL: '.split(out, "\n")[0]
endfunction

let s:nrepl = {
      \ 'call': s:function('s:nrepl_call'),
      \ 'eval': s:function('s:nrepl_eval'),
      \ 'path': s:function('s:nrepl_path'),
      \ 'process': s:function('s:nrepl_process')}

if !has('ruby')
  finish
endif

ruby <<
require 'timeout'
require 'socket'
def VIM.string_encode(str)
  '"' + str.gsub(/[\000-\037"\\]/) { |x| "\\%03o" % (x.respond_to?(:ord) ? x.ord : x[0]) } + '"'
end
def VIM.let(var, value)
  VIM.command("let #{var} = #{string_encode(value)}")
end
.

function! s:nrepl_call(payload) dict abort
  let payload = nrepl#foreplay_connection#bencode(a:payload)
  ruby <<
  begin
    buffer = ''
    Timeout.timeout(16) do
      TCPSocket.open(VIM.evaluate('self.host'), VIM.evaluate('self.port').to_i) do |s|
        s.write(VIM.evaluate('payload'))
        loop do
          body = s.readpartial(8192)
          buffer << body
          break if body.include?("6:statusl4:done")
        end
        VIM.let('out', buffer)
      end
    end
  rescue
    VIM.let('err', $!.to_s)
  end
.
  if !exists('err')
    return nrepl#foreplay_connection#bdecode('l'.out.'e')
  endif
  throw 'nREPL: '.err
endfunction

" vim:set et sw=2:
