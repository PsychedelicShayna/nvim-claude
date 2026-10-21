local M = {}

function M.notify(message, level)
  vim.schedule(function()
    vim.notify("nvim-claude: " .. message, level or vim.log.levels.INFO)
  end)
end

function M.plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

function M.read_file(path)
  local file, err = io.open(path, "rb")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

function M.write_file(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file, err = io.open(path, "wb")
  if not file then
    return nil, err
  end
  file:write(content)
  file:close()
  return true
end

function M.json_read(path, fallback)
  local content = M.read_file(path)
  if not content then
    return fallback
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return fallback
  end
  return decoded
end

function M.normalize(text, policy, replacements)
  if policy == "allow" then
    return text
  end
  local output = text
  for char, replacement in pairs(replacements) do
    output = output:gsub(char, policy == "remove" and "" or replacement)
  end
  return output
end

function M.split_lines(text)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

function M.uuid()
  local random = tostring(vim.uv.hrtime()) .. tostring(vim.fn.getpid()) .. tostring(math.random())
  return vim.fn.sha256(random):sub(1, 8) .. "-" .. vim.fn.sha256(random .. "x"):sub(1, 4)
end

function M.is_process_alive(pid)
  if type(pid) ~= "number" then
    return false
  end
  local ok, result = pcall(vim.uv.kill, pid, 0)
  return ok and result == 0
end

function M.display_error(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

return M
