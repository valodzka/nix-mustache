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
  PARTIAL = ">";

  escape = if config ? escape then config.escape else v: v;
  partialByName = if config ? partial then config.partial else v: null;
  lib = if config ? lib then config.lib else (import <nixpkgs>  { config = {}; overlays = []; }).lib;
  lists = lib.lists;
  strings = lib.strings;

  utils = {
    nullToEmpty = s: if s == null then "" else s;
    strip = string: builtins.head (builtins.match "[[:space:]]*([^[:space:]]*)[[:space:]]*" string);
    formatFloat = float:
      let
        string = toString float;
        cleaner = str: if strings.hasSuffix "0" str then cleaner (strings.removeSuffix "0" str) else str;
      in
        cleaner string;
    removeIfLast = list: targetElem:
      let
        len = builtins.length list;
        lastElem = builtins.elemAt list (len - 1);
      in
        if len == 0 || lastElem != targetElem then list else lists.sublist 0 (len - 1) list;
  };
  
  isTag = e: (builtins.isAttrs e) && e ? tag;
  
  findVariableValue = key: stack:
    let
      getValueDot = stack: (builtins.head stack).value;

      getRootValue = key: stack:
        let
          checker = data: (builtins.isAttrs data.value) && (builtins.hasAttr key data.value);
          elem = lists.findFirst checker null stack;
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
          pathParts = strings.splitString "." path;
          root = getRootValue (builtins.head pathParts) stack;
        in
          getValueNested (builtins.tail pathParts) root;
    in
      if key == "." then getValueDot stack else getValueByPath key stack;

  resolveValue = value: arg:
    let
      funcResult = if builtins.isFunction value then value arg else value;
      finalResult = if builtins.isFloat funcResult then utils.formatFloat funcResult else builtins.toString funcResult;
    in
      finalResult;

  findCloseTagIndex = list: index: stack:
    let
      elem = builtins.elemAt list index;
      mod = elem.modifier;
      tag = elem.tag;
      findNext = findCloseTagIndex list (index + 1);
    in
      if stack == [] then
        index - 1
      else
        if isTag elem && (mod == SECTION || mod == INVERT || mod == CLOSE) then
          if mod == CLOSE then
            if stack != [] && (builtins.head stack) == tag then
              findNext (builtins.tail stack)
            else
              throw "Unexpected tag close: ${tag}"
          else # section
            findNext ([tag] ++ stack)
        else
          findNext stack;

  handleElements = list: stack:
    let
      head = builtins.head list; 
    in
      if list == [] then
        ""
      else if isTag head then
        handleTag list head stack
      else
        head + (handleElements (builtins.tail list) stack);

  handleTag = list: elem: stack:
    let
      mod = elem.modifier;
      tag = elem.tag;
      val = findVariableValue tag stack;
      isFalsyVal = val == null || val == false || val == [];
      startExternal = elem.effectiveLeadingSpace;
      startInternal = elem.effectiveTrailingSpace;
      remainder = handleElements (builtins.tail list) stack;
    in
      if mod == COMMENT then
        startExternal + startInternal + remainder
      else if mod == PARTIAL then
        let
          partialTemplate = partialByName tag;
          partialTemplateResolved = if partialTemplate == null then "" else partialTemplate;
          # remove empty trailing line added during split
          partialTemplateLines = utils.removeIfLast (builtins.split "(\n|\r\n)" partialTemplateResolved) "";
          linesReducer = (text: line: text + (if builtins.isString line then elem.leadingSpace + line else builtins.head line));
          templateIndented = builtins.foldl' linesReducer "" partialTemplateLines;
          partialTemplateFinal = if elem.isStandalone then templateIndented else partialTemplateResolved;
          partialRendered = renderWithDelimiters partialTemplateFinal stack DELIMITER_START DELIMITER_END;
        in
          (if elem.isStandalone then
            partialRendered
          else
            startExternal + partialRendered + startInternal) + remainder
      else if mod == SECTION || mod == INVERT then
        let
          tail = builtins.tail list;
          closeIdx = findCloseTagIndex tail 0 [tag];
          sectionList = lists.take closeIdx tail;
          afterSectionList = lists.drop (closeIdx + 1) tail;
          invert = mod == INVERT;
          closer = builtins.elemAt tail closeIdx;
          endInternal = closer.effectiveLeadingSpace;
          endExternal = closer.effectiveTrailingSpace;
        in
          (if (isFalsyVal && !invert) || (!isFalsyVal && invert) then
            startExternal + endExternal
           else
             let
               effectiveValue = if !(builtins.isList val) then [val]
                                else if val == [] then [""]
                                else val;
             in
               (builtins.foldl' (acc: v:
                 let
                   sectionResult = handleElements sectionList ([{ value = v; }] ++ stack);
                   resolvedValue = if builtins.isFunction v then resolveValue v sectionResult else sectionResult;
                 in
                   acc + startInternal + resolvedValue + endInternal)
                 startExternal effectiveValue) + endExternal
          ) + 
          (handleElements afterSectionList stack)
      else if mod == "" || mod == UNESCAPED || mod == UNESCAPED2 then
        let
          resolvedValue = resolveValue val null;
          escapedValue = if mod == "" then escape resolvedValue else resolvedValue;
        in
          startExternal + escapedValue + startInternal + remainder
      else
        throw "Unknown modifier: ${mod}";

  canBeStandalone = mod: mod == SECTION || mod == INVERT || mod == COMMENT || mod == CLOSE || mod == PARTIAL;
  
  prepareChunks = rawList:
    let
      list = builtins.filter (e: e != "") rawList;
      tagsToAttrs = idx: element:
        if builtins.isList element then
          let
            at = builtins.elemAt element;
            leadingSpace = at 0;
            modifier = at 1;
            tag = utils.strip (at 2);
            baseTrailingSpace = at 3;
            trailingLf = at 4;

            hasLeadingLf = let
              endsWithLf = s: s != null && ((strings.hasSuffix "\n" s) || (strings.hasSuffix "\r\n" s));
              elemEndsWithLf = e: if builtins.isList e then endsWithLf (builtins.elemAt e 4) else endsWithLf e;
              prevEl = builtins.elemAt list (idx - 1);
            in
              idx == 0 || (elemEndsWithLf prevEl);
          in rec {
            inherit tag modifier leadingSpace;
            trailingSpace = baseTrailingSpace + (utils.nullToEmpty trailingLf);
            effectiveLeadingSpace = if isStandalone then "" else leadingSpace;
            effectiveTrailingSpace = if isStandalone then "" else trailingSpace;
            isStandalone = (canBeStandalone modifier) && trailingLf != null && hasLeadingLf;
          }
        else
          element;
    in
      lists.imap0 tagsToAttrs list;
  
  renderWithDelimiters = template: stack: delimiterStartRaw: delimiterEndRaw:
    let
      delimiterStart = strings.escapeRegex delimiterStartRaw;
      delimiterEnd = strings.escapeRegex delimiterEndRaw;
      tagExcludeChar = strings.escapeRegex (builtins.substring 0 1 delimiterEndRaw);
      splitRe = "([[:blank:]]*)" + delimiterStart + "([#/!&^{>]?)([^" + tagExcludeChar + "]+)}?" + delimiterEnd + "([[:blank:]]*)($|\n|\r\n)?";
      splited = builtins.split splitRe template;
      matches = prepareChunks splited;
    in
      handleElements matches [{ value = view; }];

  renderTemplate = template: view:
    renderWithDelimiters template [{ value = view;}] DELIMITER_START DELIMITER_END;
  
in renderTemplate template view
        
