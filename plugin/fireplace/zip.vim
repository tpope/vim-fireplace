" fireplace/zip.vim: zip.vim monkey patch to allow access from quickfix
" Maintainer:   Tim Pope <http://tpo.pe>

if exists("g:loaded_zip") || &cp
  finish
endif

runtime! autoload/zip.vim

" Copied and pasted verbatim from autoload/zip.vim.

fun! zip#Read(fname,mode)
"  call Dfunc("zip#Read(fname<".a:fname.">,mode=".a:mode.")")
  let repkeep= &report
  set report=10

  if has("unix")
   let zipfile = substitute(a:fname,'zipfile:\(.\{-}\)::[^\\].*$','\1','')
   let fname   = substitute(a:fname,'zipfile:.\{-}::\([^\\].*\)$','\1','')
  else
   let zipfile = substitute(a:fname,'^.\{-}zipfile:\(.\{-}\)::[^\\].*$','\1','')
   let fname   = substitute(a:fname,'^.\{-}zipfile:.\{-}::\([^\\].*\)$','\1','')
   let fname = substitute(fname, '[', '[[]', 'g')
  endif
"  call Decho("zipfile<".zipfile.">")
"  call Decho("fname  <".fname.">")

  " Changes for fireplace.
  let temp = tempname()
  let fn = expand('%:p')
  exe "sil! ! ".g:zip_unzipcmd." -p -- ".shellescape(zipfile,1)." ".shellescape(fnameescape(fname),1). ' > '.temp
  silent exe 'keepalt file '.temp
  silent keepjumps edit!
  silent exe 'keepalt file '.fnameescape(fn)
  call delete(temp)
  filetype detect

  " Resume regularly scheduled programming.
  set nomod
endfun
