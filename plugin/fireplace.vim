" fireplace.vim - Clojure REPL support
" Maintainer:   Tim Pope <http://tpo.pe/>
" Version:      1.2
" GetLatestVimScripts: 4978 1 :AutoInstall: fireplace.vim

if exists("g:loaded_fireplace")
  finish
endif
let g:loaded_fireplace = 1

augroup fireplace
  autocmd!

  if has('job') || exists('*jobstart')
    autocmd FileType clojure call fireplace#activate()

    autocmd QuickFixCmdPost make,cfile,cgetfile
          \ if &efm =~# 'classpath' | call fireplace#massage_list() | endif
    autocmd QuickFixCmdPost lmake,lfile,lgetfile
          \ if &efm =~# 'classpath' | call fireplace#massage_list(0) | endif
  else
    autocmd FileType clojure
          \ if !exists('s:did_warning') |
          \    let s:did_warning = 1 |
          \    echohl WarningMsg |
          \    echo 'Fireplace not loaded: Vim 8.0 or higher required' |
          \    echohl None
          \ endif
  endif
augroup END

command! -bar -bang -complete=customlist,fireplace#connect_complete -nargs=* FireplaceConnect
      \ exe fireplace#connect_command(<line1>, <line2>, +'<range>', <count>, <bang>0, '<mods>', <q-reg>, <q-args>, [<f-args>])
