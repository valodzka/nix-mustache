{ template, view, config ? {} }:
let
  DELIMITER_START = "{{";
  DELIMITER_END = "}}";
  COMMENT = "!";
  SECTION = "#";
  INVERT = "^";
  UNESCAPED = "&";
  UNESCAPED2 = "{";
  CLOSE = "/";

  escapeFunction = if config ? escapeFunction then config.escapeFunction else v: v;
  lib = if config ? lib then config.lib else (import <nixpkgs>  { config = {}; overlays = []; }).lib;

  strip = string: builtins.head (builtins.match "[[:space:]]*([^[:space:]]*)[[:space:]]*" string);
  formatFloat = float:
    let
      string = toString float;
      cleaner = str: if lib.strings.hasSuffix "0" str then cleaner (lib.strings.removeSuffix "0" str) else str;
    in
      cleaner string;

  isFalsy = v: v == null || v == false;
  nullToEmpty = v: if v == null then "" else v;

  getter = rec {
    modifier = a: builtins.elemAt a 2;
    tag = a: strip (builtins.elemAt a 3);
    leadingSpace = a: builtins.elemAt a 0;
    trailingSpace = a: builtins.elemAt a 4;
    spacing = a: let
      leading = leadingSpace a;
      trailing = trailingSpace a;
    in
      if leading != null && trailing != null then
        let
          newLineType = if lib.strings.hasPrefix "\r\n" leading || lib.strings.hasSuffix "\r\n" trailing then "\r\n" else "\n";
          newLineSep = if lib.strings.hasPrefix newLineType leading then newLineType else "";
        in
          newLineSep
      else
        (nullToEmpty leading) + (nullToEmpty trailing);
  };

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
    let
      funcResult = if builtins.isFunction value then value arg else value;
      finalResult = if builtins.isFloat funcResult then formatFloat funcResult else builtins.toString funcResult;
    in
      finalResult;

  findCloseTagIndex = list: index: stack:
    let
      currentElem = builtins.elemAt list index;
      mod = getter.modifier currentElem;
      tag = getter.tag currentElem;
      findNext = findCloseTagIndex list (index + 1);
    in
      if stack == [] then
        index - 1
      else
        if builtins.isList currentElem && (mod == SECTION || mod == INVERT || mod == CLOSE) then
          if mod == CLOSE then
            if stack != [] && (builtins.head stack) == tag then
              findNext (builtins.tail stack)
            else
              throw "Unexpected tag close: ${tag}"
          else # start of section
            findNext ([tag] ++ stack)
        else
          findNext stack;
          
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
      mod = getter.modifier chunk;
      tag = getter.tag chunk;
      leadingSpace = getter.leadingSpace chunk;
      trailingSpace = getter.trailingSpace chunk;
      spacing = getter.spacing chunk;
      val = getVariableValue tag stack;
    in
      if mod == COMMENT then
        spacing + (handleElements (builtins.tail list) stack)
      else if mod == SECTION || mod == INVERT then
        let
          tail = builtins.tail list;
          closeIdx = findCloseTagIndex tail 0 [tag];
          sectionList = lib.lists.take closeIdx tail;
          closeTag = builtins.elemAt tail closeIdx;
          afterSectionList = lib.lists.drop (closeIdx + 1) tail;
          invert = mod == INVERT;
          closeSpacing = getter.spacing closeTag;
        in
          (if ((isFalsy val) && !invert) || (!(isFalsy val) && invert) then
            spacing
           else
             builtins.foldl' (acc: v:
               let
                 sectionResult = handleElements sectionList ([{ value = v; tag = tag; active = true; }] ++ stack);
               in
                 acc + spacing + (if builtins.isFunction v then resolveValue v sectionResult else sectionResult) + closeSpacing)
               "" (lib.lists.toList val)
          ) + 
          (handleElements afterSectionList stack)
      else if mod == "" || mod == UNESCAPED || mod == UNESCAPED2 then
        let
          resolvedValue = resolveValue val null;
          escapedValue = if mod == "" then escapeFunction resolvedValue else resolvedValue;
        in
          (nullToEmpty leadingSpace) + escapedValue + (nullToEmpty trailingSpace) + (handleElements (builtins.tail list) stack)
      else
        throw "Unknown modifier: ${mod}";

  renderWithDelimieters = template: view: delimiterStartRaw: delimiterEndRaw:
    let
      delimiterStart = lib.strings.escapeRegex delimiterStartRaw;
      delimiterEnd = lib.strings.escapeRegex delimiterEndRaw;
      tagExcludeChar = lib.strings.escapeRegex (builtins.substring 0 1 delimiterEndRaw);
      splitRe = "((^|\n|\r\n)[[:blank:]]*)?" + delimiterStart + "([#/!&^{]?)([^" + tagExcludeChar + "]+)}?" + delimiterEnd + "([[:blank:]]*($|\n|\r\n))?";
      matches = builtins.split splitRe template;
    in
      handleElements matches [{ value = view; tag = null; active = true; }];

  renderTemplate = template: view:
    renderWithDelimieters template view DELIMITER_START DELIMITER_END;
  
in renderTemplate template view
        
