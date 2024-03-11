{ template, view, config ? {} }:
let
  DELIMITER_START = "{{";
  DELIMITER_END = "}}";
  COMMENT = "!";
  SECTION = "#";
  INVERT = "^";
  UNESCAPED = "&";
  CLOSE = "/";

  escapeFunction = if config ? escapeFunction then config.escapeFunction else v: v;
  lib = if config ? lib then config.lib else (import <nixpkgs>  { config = {}; overlays = []; }).lib;

  isFalsy = v: v == null || v == false;

  getVariableValue = key: stack:
    let
      getValueDot = stack: (builtins.head stack).value;

      getValueFromAttr = key: stack:
        let
          checker = data: (builtins.isAttrs data.value) && (builtins.hasAttr key data.value);
          elem = lib.lists.findFirst checker null stack;
        in
          if elem != null then elem.value.${key} else null;

      getValueNested = pathParts: obj:
        let
          attr = builtins.head pathParts;
          tail = builtins.tail pathParts;
        in
          if pathParts == [] then
            obj
          else if (builtins.isAttrs obj) && (builtins.hasAttr attr obj) then
            getValueNested tail obj.${attr}
          else
            null;

      getValueByPath = path: stack:
        let
          pathParts = lib.strings.splitString "." path;
          root = getValueFromAttr (builtins.head pathParts) stack;
        in
          getValueNested (builtins.tail pathParts) root;
    in
      if key == "." then getValueDot stack else getValueByPath key stack;

  resolveValue = value: arg:
    builtins.toString (if builtins.isFunction value then value arg else value);

  findCloseIndex = list: name: let
    matcher = v: (builtins.isList v) && (builtins.head v) == CLOSE && (builtins.elemAt v 1) == name;
    idx = lib.lists.findFirstIndex matcher null list;
  in
    if idx == null then throw "Closing tag for ${name} not found" else idx;

  handleElements = list: stack:
    let
      head = if list != [] then builtins.head list else null; 
    in
      if head == null then
        ""
      else if builtins.isList head then
        (handleTag list head stack)
      else
        (head + (handleElements (builtins.tail list) stack));

  handleTag = list: chunk: stack:
    let
      mod = builtins.head chunk;
      tag = builtins.elemAt chunk 1;
      val = getVariableValue tag stack;
    in
      if mod == COMMENT then
        (handleElements (builtins.tail list) stack)
      else if mod == SECTION || mod == INVERT then
        let
          tail = builtins.tail list;
          closeIdx = findCloseIndex tail tag;
          sectionList = lib.lists.take closeIdx tail;
          afterSectionList = lib.lists.drop (closeIdx + 1) tail;
          invert = mod == INVERT;
        in
          (if ((isFalsy val) && !invert) || (!(isFalsy val) && invert) then
            ""
           else
             builtins.foldl' (acc: v:
               let
                 sectionResult = handleElements sectionList ([{ value = v; tag = tag; active = true; }] ++ stack);
               in
                 acc + (if builtins.isFunction v then resolveValue v sectionResult else sectionResult))
               "" (lib.lists.toList val)
          ) +
          (handleElements afterSectionList stack)
      else if mod == "" || mod == UNESCAPED then
        let
          resolvedValue = resolveValue val null;
          escapedValue = if mod == UNESCAPED then resolvedValue else escapeFunction resolvedValue;
        in
          escapedValue + (handleElements (builtins.tail list) stack)
      else
        throw "Unknown modifier: ${mod}";

  renderTemplate = template: view:
    let
      delimiterStart = lib.strings.escapeRegex DELIMITER_START;
      delimiterEnd = lib.strings.escapeRegex DELIMITER_END;
      tagExcludeChar = lib.strings.escapeRegex (builtins.substring 0 1 DELIMITER_END);
      splitRe = delimiterStart + "([#/!&^]?)([^" + tagExcludeChar + "]+)" + delimiterEnd;
      matches = builtins.split splitRe template;
    in
      handleElements matches [{ value = view; tag = null; active = true; }];
  
in renderTemplate template view
        
