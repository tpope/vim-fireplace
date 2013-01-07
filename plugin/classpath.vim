" classpath.vim - Set 'path' from the Java class path
" Maintainer:   Tim Pope <http://tpo.pe/>

if exists('g:no_foreplay_classpath') || exists("g:loaded_classpath") || v:version < 700 || &cp
  finish
endif
let g:loaded_classpath = 1

if &viminfo !~# '!'
  set viminfo+=!
endif

augroup classpath
  autocmd!
  autocmd FileType clojure
        \ if expand('%:p') =~# '^zipfile:' |
        \   let &l:path = getbufvar('#', '&path') |
        \ else |
        \   let &l:path = classpath#detect() |
        \ endif
augroup END

" vim:set et sw=2:
