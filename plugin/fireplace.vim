" fireplace.vim - Clojure REPL support
" Maintainer:   Tim Pope <http://tpo.pe/>
" Version:      2.1
" GetLatestVimScripts: 4978 1 :AutoInstall: fireplace.vim

if exists("g:loaded_fireplace")
  finish
endif
let g:loaded_fireplace = 1

augroup fireplace
  autocmd!

  if v:version >= 800
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

  autocmd User ProjectionistActivate
        \ for b:fireplace_cljs_repl in projectionist#query_scalar('fireplaceCljsRepl') + projectionist#query_scalar('cljsRepl') |
        \   break |
        \ endfor
augroup END

command! -bar -bang -complete=customlist,fireplace#ConnectComplete -nargs=* FireplaceConnect
      \ exe fireplace#ConnectCommand(<line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>, [<f-args>])
command! -bang -range -complete=customlist,fireplace#CljEvalComplete -nargs=* CljEval
      \ exe fireplace#CljEvalCommand( <line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>)
command! -bang -range -complete=customlist,fireplace#CljsEvalComplete -nargs=* CljsEval
      \ exe fireplace#CljsEvalCommand(<line1>, <count>, +'<range>', <bang>0, <q-mods>, <q-args>)
