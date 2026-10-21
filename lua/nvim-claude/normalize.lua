local M = {}

local replacements = {
  ["—"] = "-",
  ["–"] = "-",
  ["‘"] = "'",
  ["’"] = "'",
  ["“"] = '"',
  ["”"] = '"',
  ["…"] = "...",
  [" "] = " ",
}

function M.apply(text, policy)
  if policy == "allow" then return text end
  for character, replacement in pairs(replacements) do
    text = text:gsub(character, policy == "remove" and "" or replacement)
  end
  return text
end

return M
