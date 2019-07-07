" fireplace.vim - Clojure REPL support
" Maintainer:   Tim Pope <http://tpo.pe/>
" Version:      1.2
" GetLatestVimScripts: 4978 1 :AutoInstall: fireplace.vim

if exists("g:loaded_fireplace") || v:version < 800 || &compatible
  finish
endif
let g:loaded_fireplace = 1

augroup fireplace
  autocmd!
  autocmd FileType clojure call fireplace#activate()

  autocmd QuickFixCmdPost make,cfile,cgetfile
        \ if &efm =~# 'classpath' | call fireplace#massage_list() | endif
  autocmd QuickFixCmdPost lmake,lfile,lgetfile
        \ if &efm =~# 'classpath' | call fireplace#massage_list(0) | endif
augroup END

command! -bar -bang -complete=customlist,fireplace#connect_complete -nargs=* FireplaceConnect
      \ exe fireplace#connect_command(<line1>, <line2>, +'<range>', <count>, <bang>0, '<mods>', <q-reg>, <q-args>, [<f-args>])
