local M = {}

local replacements = {
  { "—", "-" },
  { "–", "-" },
  { "‘", "'" },
  { "’", "'" },
  { "“", '"' },
  { "”", '"' },
  { "…", "..." },
  { " ", " " },
}

function M.is_valid(policy)
  return policy == "allow" or policy == "remove" or policy == "replace"
end

function M.apply(text, policy)
  if type(text) ~= "string" then
    error("punctuation input must be a string")
  end
  policy = policy or "allow"
  if policy == "allow" then
    return text
  end
  if policy ~= "remove" and policy ~= "replace" then
    error("unknown punctuation policy: " .. tostring(policy))
  end

  local result = text
  for _, entry in ipairs(replacements) do
    result = result:gsub(entry[1], policy == "replace" and entry[2] or "")
  end
  return result
end

return M
