local fireplace_impl = {[vim.type_idx]=vim.types.dictionary}

if vim.treesitter then
  local has_ts, ts = pcall(require, 'nvim-treesitter.ts_utils')

  if has_ts and vim.treesitter.require_language('clojure', nil, true) then
    fireplace_impl['get_completion_context'] = function()
      vim.treesitter.get_parser(0, 'clojure'):parse()
      local node = ts.get_node_at_cursor()
      local one_ago = nil
      local two_ago = nil

      while(node ~= nil) do
        two_ago = one_ago
        one_ago = node
        node = node:parent()
      end

      local root_node = two_ago or one_ago or node

      if root_node ~= nil then
        local strs = ts.get_node_text(root_node)
        local nrow1,ncol1,nline2,ncol2 = root_node:range()
        local crow,ccol = unpack(vim.api.nvim_win_get_cursor(0))

        local idx = crow - nrow1
        local line = strs[idx]
        local coloffset = 0
        if crow == nrow1 then
          coloffset = ncol1
        end

        strs[idx] = string.sub(line, 1 + coloffset, ccol + coloffset) .. ' __prefix__ ' .. string.sub(line, ccol+coloffset+1, -1)

        return table.concat(strs, "\n")
      else
        return ""
      end
    end
  end
end

return fireplace_impl
