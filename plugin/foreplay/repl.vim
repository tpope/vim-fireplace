
" Evaluate a string form on the given repl
" Returns a dictionary with the stdout, stderr,
" result, and repl status metadata
function! foreplay#repl#eval(form)
  if !exists('b:repl_id')
    throw "Can only do repl eval in a repl buffer!"
  endif
  let escaped_form = escape(a:form,'\"')
  let full_form = '(redl.core/repl-eval '.b:repl_id .
                          \ ' (read-string "(do '.escaped_form.')"))'
  echo 'full form = '.full_form
  return foreplay#evalparse(full_form)
endfunction

" Returns the prompt for the namespace the repl is
" currently in. Also includes how many levels of debug
" are currently in use.
function! foreplay#repl#prompt()
  let prompt = b:repl_namespace
  if b:repl_depth > 0
    let prompt .= ':debug-' . b:repl_depth
  endif
  return prompt.'=>'
endfunction

" Moves the cursor to the beginning of the line,
" respecting the prompt as the beginning
function! foreplay#repl#beginning_of_line()
	let l = getline(".")

    let prompt = foreplay#repl#prompt()
	if l =~ "^".prompt
		let [buf, line, col, off] = getpos(".")
		call setpos(".", [buf, line, len(prompt) + 2, off])
	else
		normal! ^
	endif
endfunction

" Appends the given lines to the end of the buffer
function! foreplay#repl#show_text(lines)
  call append(line('$'), split(a:lines, "\n"))
endfunction

" When invoked, writes out the prompt in a new line,
" and moves the cursor to the prompt in insert mode.
function! foreplay#repl#show_prompt()
  call foreplay#repl#show_text(foreplay#repl#prompt().' ')
  normal! G
  startinsert!
endfunction

inoremap <Plug>clj_repl_enter. <Esc>:call foreplay#repl#enter_hook()<CR>
inoremap <Plug>clj_repl_eval. <Esc>G$:call foreplay#repl#enter_hook()<CR>
nnoremap <Plug>clj_repl_hat. :call foreplay#repl#beginning_of_line()<CR>
nnoremap <Plug>clj_repl_Ins. :call foreplay#repl#beginning_of_line()<CR>i
inoremap <Plug>clj_repl_uphist. <C-O>:call foreplay#repl#up_history()<CR>
inoremap <Plug>clj_repl_downhist. <C-O>:call foreplay#repl#down_history()<CR>

" This creates a new repl in a split
function! foreplay#repl#create(namespace)
  new
  setlocal buftype=nofile
  setlocal noswapfile
  set filetype=clojure
  let ns = "'".a:namespace
  let b:repl_id = foreplay#evalparse('(redl.core/make-repl '.ns.')')
  let b:repl_namespace = a:namespace
  let b:repl_depth = 0
  let b:repl_history_depth = 0
  let b:repl_history = []

  if !hasmapto("<Plug>clj_repl_enter.", "i")
    imap <buffer> <silent> <CR> <Plug>clj_repl_enter.
  endif
  if !hasmapto("<Pulg>clj_repl_eval.", "i")
    imap <buffer> <silent> <C-e> <Plug>clj_repl_eval.
  endif
  if !hasmapto("<Plug>clj_repl_hat.", "n")
    nmap <buffer> <silent> ^ <Plug>clj_repl_hat.
  endif
  if !hasmapto("<Plug>clj_repl_Ins.", "n")
    nmap <buffer> <silent> I <Plug>clj_repl_Ins.
  endif
  if !hasmapto("<Plug>clj_repl_uphist.", "i")
    imap <buffer> <silent> <C-Up> <Plug>clj_repl_uphist.
  endif
  if !hasmapto("<Plug>clj_repl_downhist.", "i")
    imap <buffer> <silent> <C-Down> <Plug>clj_repl_downhist.
  endif

  call foreplay#repl#show_prompt()
endfunction

" Like pressing enter in insert mode.
" This was lifted from vimclojure, and appears to do
" other fixups to the line.
function! foreplay#repl#do_enter()
	execute "normal! a\<CR>x"
	normal! ==x
	if getline(".") =~ '^\s*$'
		startinsert!
	else
		startinsert
	endif
endfunction

function! foreplay#repl#get_command()
	let ln = line("$")

    let prompt = foreplay#repl#prompt()
	while getline(ln) !~ "^".prompt && ln > 0
		let ln = ln - 1
	endwhile

	" Special Case: User deleted Prompt by accident. Insert a new one.
	if ln == 0
		call foreplay#repl#show_prompt()
		return ""
	endif

	let cmd = foreplay#util#Yank("l", ln.",".line("$")."yank l")

	let cmd = substitute(cmd, "^".prompt."\\s*", "", "")
	let cmd = substitute(cmd, "\n$", "", "")
	return cmd
endfunction

" Returns 1 if the given string results in a readable form,
" 0 otherwise.
function! foreplay#repl#is_readable(form)
  let test_form = '(try (read-string "' .
                          \ escape(a:form, '\"').'") 1 ' .
                          \ '(catch RuntimeException _ 0))'
  let result = foreplay#evalparse(test_form)
  return result
endfunction

function! foreplay#repl#enter_hook()
	let lastCol = {}

	function lastCol.f() dict
		normal! g_
		return col(".")
	endfunction

    let last_col = foreplay#util#WithSavedPosition(lastCol)
    if line(".") < line("$") || col(".") < last_col
		call foreplay#repl#do_enter()
		return
	endif

	let cmd = foreplay#repl#get_command()

	" Special Case: Showed prompt (or user just hit enter).
	if cmd =~ '^\(\s\|\n\)*$'
		execute "normal! a\<CR>"
		startinsert!
		return
	endif

    "Currently unused feature (special commands)
	"if self.isReplCommand(cmd)
		"call self.doReplCommand(cmd)
		"return
	"endif

	if !foreplay#repl#is_readable(cmd)
		call foreplay#repl#do_enter()
	else
        let result = foreplay#repl#eval(cmd)
		call foreplay#repl#show_text(result.out)
        if result.err !=# ''
          call foreplay#repl#show_text("\nstderr:\n".result.err)
        endif

		let b:repl_history_depth = 0
		let b:repl_history = [cmd] + b:repl_history
        let b:repl_namespace = result.ns
        let b:repl_depth = result['repl-depth']

        call foreplay#repl#show_prompt()
	endif
endfunction

inoremap <Plug>clj_repl_uphist. <C-O>:call foreplay#repl#up_history()<CR>
inoremap <Plug>clj_repl_downhist. <C-O>:call foreplay#repl#down_history()<CR>

function! foreplay#repl#delete_last()
	normal! G

	while getline("$") !~ foreplay#repl#prompt()
		normal! dd
	endwhile

	normal! dd
endfunction

function! foreplay#repl#up_history()
	let histLen = len(b:repl_history)
	let histDepth = b:repl_history_depth

	if histLen > 0 && histLen > histDepth
		let cmd = b:repl_history[histDepth]
		let b:repl_history_depth = histDepth + 1

		call foreplay#repl#delete_last()

        let prompt = foreplay#repl#prompt()
		call foreplay#repl#show_text(prompt.' '.cmd)
	endif

	normal! G$
endfunction

function! foreplay#repl#down_history()
	let histLen = len(b:repl_history)
	let histDepth = b:repl_history_depth
    let prompt = foreplay#repl#prompt()

	if histDepth > 0 && histLen > 0
		let b:repl_history_depth = histDepth - 1
		let cmd = b:repl_history[b:repl_history_depth]

		call foreplay#repl#delete_last()

		call foreplay#repl#show_text(prompt.' '.cmd)
	elseif histDepth == 0
		call foreplay#repl#delete_last()
		call foreplay#repl#show_text(prompt.' ')
	endif

	normal! G$
endfunction


"TODO:
"-repl history
"--for this, need to store which index we're currently looking at
"and the entire history
"--also need a deleteLast/replaceLastWith function
"--when eval occurs, reset history pointer to latest
"
"-keyboard commands: ctrl-up, ctrl-down
"-multi-expr evaluation
