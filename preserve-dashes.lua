function Str(s)
  s.text = s.text:gsub('%-%-', '\-\-')
  return s
end
