" autoload/classpath.vim
" Maintainer:   Tim Pope <http://tpo.pe>

if exists("g:autoloaded_classpath")
  finish
endif
let g:autoloaded_classpath = 1

function! classpath#separator() abort
 return has('win32') ? ';' : ':'
endfunction

function! classpath#file_separator() abort
 return exists('shellslash') && !&shellslash ? '\' : '/'
endfunction

function! classpath#split(cp) abort
  return split(a:cp, classpath#separator())
endfunction

function! classpath#to_vim(cp) abort
  let path = []
  for elem in classpath#split(a:cp)
    let path += [elem ==# '.' ? '' : elem]
  endfor
  if a:cp =~# '\(^\|:\)\.$'
    let path += ['']
  endif
  return join(map(path, 'escape(v:val, ", ")'), ',')
endfunction

function! classpath#from_vim(path) abort
  if a:path =~# '^,\=$'
    return '.'
  endif
  let path = []
  for elem in split(substitute(a:path, ',$', '', ''), ',')
    if elem ==# ''
      let path += ['.']
    else
      let path += split(glob(substitute(elem, '\\\ze[\\ ,]', '', 'g'), 1), "\n")
    endif
  endfor
  return join(path, classpath#separator())
endfunction

function! classpath#detect(...) abort
  let sep = classpath#file_separator()

  let buffer = a:0 ? a:1 : '%'
  let default = $CLASSPATH ==# '' ? ',' : classpath#to_vim($CLASSPATH)
  let root = getbufvar(buffer, 'java_root')
  if root ==# ''
    let root = simplify(fnamemodify(bufname(buffer), ':p:s?[\/]$??'))
  endif

  if !isdirectory(fnamemodify(root, ':h'))
    return default
  endif

  let previous = ""
  while root !=# previous
    if isdirectory(root . '/src')
      if filereadable(root . '/project.clj')
        let file = 'project.clj'
        let cmd = 'lein classpath'
        let pattern = "[^\n]*\\ze\n*$"
        let default = join(map(['test', 'src', 'dev-resources', 'resources', 'target'.sep.'classes'], 'escape(root . sep . v:val, ", ")'), ',')
        let base = ''
        break
      endif
      if filereadable(root . '/pom.xml')
        let file = 'pom.xml'
        let cmd = 'mvn dependency:build-classpath'
        let pattern = '\%(^\|\n\)\zs[^[].\{-\}\ze\n'
        let base = escape(root.sep.'src'.sep.'*'.sep.'*', ', ') . ','
        let default = base . default
        break
      endif
    endif
    let previous = root
    let root = fnamemodify(root, ':h')
  endwhile

  if !exists('file')
    if a:0 > 1 && a:2 ==# 'keep'
      return ''
    else
      return default
    endif
  endif

  if !exists('g:CLASSPATH_CACHE') || type(g:CLASSPATH_CACHE) != type({})
    unlet! g:CLASSPATH_CACHE
    let g:CLASSPATH_CACHE = {}
  endif

  let [when, last, path] = split(get(g:CLASSPATH_CACHE, root, "-1\t-1\t."), "\t")
  let disk = getftime(root . sep . file)
  if last ==# disk
    return path
  else
    try
      if &verbose
        echomsg 'Determining class path with '.cmd.' ...'
      endif
      let cd = exists('*haslocaldir') && haslocaldir() ? 'lcd ' : 'cd '
      let dir = getcwd()
      try
        execute cd . fnameescape(root)
        let out = system(cmd)
      finally
        execute cd . fnameescape(dir)
      endtry
    catch /^Vim:Interrupt/
      return default
    endtry
    let match = matchstr(out, pattern)
    if !v:shell_error && exists('out') && out !=# ''
      let path = base . classpath#to_vim(match)
      let g:CLASSPATH_CACHE[root] = localtime() . "\t" . disk . "\t" . path
      return path
    else
      echohl WarningMSG
      echomsg "Couldn't determine class path."
      echohl NONE
      echo out
      return default
    endif
  endif
endfunction

" vim:set et sw=2:
