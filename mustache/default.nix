{ template, view, config ? {} }:
let
  DEFAULT_DELIMITER_START = "{{";
  DEFAULT_DELIMITER_END = "}}";
  COMMENT = "!";
  SECTION = "#";
  INVERT = "^";
  UNESCAPED = "&";
  UNESCAPED2 = "{";
  CLOSE = "/";
  PARTIAL = ">";

  lib = config.lib or (import <nixpkgs>  { config = {}; overlays = []; }).lib;
  inherit (lib) lists strings;

  cfg = {
    partial = config.partial or (v: null);
    escape = config.escape or (v: v);
  };

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
      openLeading = elem.effectiveLeadingSpace;
      openTrailing = elem.effectiveTrailingSpace;
      remainder = handleElements (builtins.tail list) stack;
    in
      if mod == COMMENT then
        openLeading + openTrailing + remainder
      else if mod == PARTIAL then
        let
          partialTemplate = cfg.partial tag;
          partialTemplateResolved = if partialTemplate == null then "" else partialTemplate;
          # remove empty trailing line added during split
          partialTemplateLines = utils.removeIfLast (builtins.split "(\n|\r\n)" partialTemplateResolved) "";
          linesReducer = text: line: text + (if builtins.isString line then elem.leadingSpace + line else builtins.head line);
          templateIndented = builtins.foldl' linesReducer "" partialTemplateLines;
          partialTemplateFinal = if elem.isStandalone then templateIndented else partialTemplateResolved;
          partialRendered = renderWithDelimiters partialTemplateFinal stack DEFAULT_DELIMITER_START DEFAULT_DELIMITER_END;
        in
          (if elem.isStandalone then
            partialRendered
          else
            openLeading + partialRendered + openTrailing) + remainder
      else if mod == SECTION || mod == INVERT then
        let
          tail = builtins.tail list;
          closeIdx = findCloseTagIndex tail 0 [tag];
          sectionList = lists.take closeIdx tail;
          afterSectionList = lists.drop (closeIdx + 1) tail;
          invert = mod == INVERT;
          closer = builtins.elemAt tail closeIdx;
          endLeading = closer.effectiveLeadingSpace;
          endTrailing = closer.effectiveTrailingSpace;
        in
          (if (isFalsyVal && !invert) || (!isFalsyVal && invert) then
            openLeading + endTrailing
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
                   acc + openTrailing + resolvedValue + endLeading)
                 openLeading effectiveValue) + endTrailing
          ) + (handleElements afterSectionList stack)
      else if mod == "" || mod == UNESCAPED || mod == UNESCAPED2 then
        let
          resolvedValue = resolveValue val null;
          escapedValue = if mod == "" then cfg.escape resolvedValue else resolvedValue;
        in
          openLeading + escapedValue + openTrailing + remainder
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
  
  renderWithConstantDelimiters = template: stack: delimiterStart: delimiterEnd:
    let
      delimiterStartEscaped = strings.escapeRegex delimiterStart;
      delimiterEndEscaped = strings.escapeRegex delimiterEnd;
      tagExcludeChar = strings.escapeRegex (builtins.substring 0 1 delimiterEnd);
      splitRe = "([[:blank:]]*)" + delimiterStartEscaped + "([#/!&^{>]?)([^" + tagExcludeChar + "]+)}?" + delimiterEndEscaped + "([[:blank:]]*)($|\n|\r\n)?";
      splited = builtins.split splitRe template;
      matches = prepareChunks splited;
    in
      handleElements matches stack;
  
  renderWithDelimiters = template: stack: delimiterStart: delimiterEnd:
    let
      delimiterStartEscaped = strings.escapeRegex delimiterStart;
      delimiterEndEscaped = strings.escapeRegex delimiterEnd;
      splitRe = "((^|\n|\r\n)?([[:blank:]]*)" + delimiterStartEscaped +
                "=[[:blank:]]*([^[:blank:]]+)[[:blank:]]+([^[:blank:]{]+)[[:blank:]]*=" +
                delimiterEndEscaped + "([[:blank:]]*)($|\n|\r\n)?)";
      splited = builtins.split splitRe template;
      
      parts = builtins.length splited;
      at = builtins.elemAt (builtins.elemAt splited 1);
      leadingLf = at 1;
      leadingSp = at 2;
      newDelimiterStart = at 3;
      newDelimiterEnd = at 4;
      trailingSp = at 5;
      trailingLf = at 6;
      reducer = acc: e: acc + (if builtins.isString e then e else builtins.head e);
      partWithNewDelimiters = builtins.foldl' reducer "" (lists.drop 2 splited);
      isStandalone = leadingLf != null && trailingLf != null;
      spacing = (utils.nullToEmpty leadingLf) + (if isStandalone then "" else leadingSp + trailingSp + (utils.nullToEmpty trailingLf));
      
      renderedWithOriginalDelimiters = renderWithConstantDelimiters (builtins.head splited) stack delimiterStart delimiterEnd;
      renderedWithNewDelimiters = spacing + (renderWithDelimiters partWithNewDelimiters stack newDelimiterStart newDelimiterEnd);
    in
      renderedWithOriginalDelimiters + 
      (if parts == 1 then "" 
       else if parts > 2 then renderedWithNewDelimiters
       else throw "Unexpected number of parts: ${toString parts}")
  ;
  
  renderTemplate = template: view:
    let
      templateContent = if builtins.isPath template then builtins.readFile template else template;
    in
      renderWithDelimiters templateContent [{ value = view;}] DEFAULT_DELIMITER_START DEFAULT_DELIMITER_END;
  
in renderTemplate template view
        
