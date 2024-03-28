{ lib }:
{ template, view, config ? {}}:
let
  inherit (lib) lists strings;
  
  DEFAULT_DELIMITER_START = "{{";
  DEFAULT_DELIMITER_END = "}}";
  COMMENT = "!";
  SECTION = "#";
  INVERT = "^";
  UNESCAPED = "&";
  UNESCAPED2 = "{";
  CLOSE = "/";
  PARTIAL = ">";
  ESCAPED = "";

  cfg = {
    partial = config.partial or (v: null);
    escape = config.escape or (v: v);
  };

  utils = {
    nullToEmpty = s: if s == null then "" else s;
    strip = string: builtins.head (builtins.match "[[:space:]]*([^[:space:]]*)[[:space:]]*" string);
    hasAttr = key: attrs: (builtins.isAttrs attrs) && (builtins.hasAttr key attrs);
    formatFloat = float:
      let
        string = toString float;
        cleaner = str: if strings.hasSuffix "0" str then cleaner (strings.removeSuffix "0" str) else str;
      in
        cleaner string;
    removeIfLast = list: targetElem:
      let
        len = builtins.length list;
        lastElem = lists.last list;
      in
        if len == 0 || lastElem != targetElem then list else lists.init list;
  };
  
  isTag = utils.hasAttr "tag";

  formatTagPath = list:
    lib.trivial.pipe list [
      (builtins.filter (v: v != ""))
      lists.reverseList
      (builtins.concatStringsSep "/")
      (v: "\"/${v}\"")
    ];
  
  findVariableValue = key: stack:
    let
      findRoot = key: stack:
        let
          elem = lists.findFirst (v: utils.hasAttr key v.value) null stack;
        in
          if elem != null then elem.value.${key} else null;

      findValueByPath = path: stack:
        let
          pathParts = strings.splitString "." path;
          root = findRoot (builtins.head pathParts) stack;
        in
          lib.attrsets.attrByPath (builtins.tail pathParts) null root;
    in
      if key == "." then (builtins.head stack).value else findValueByPath key stack;

  coerceValue = stackPath: value:
    if builtins.isFloat value then utils.formatFloat value
    else if strings.isConvertibleWithToString  value then builtins.toString value
    else throw "Connot coerce object to string for key path ${stackPath}: ${builtins.typeOf value}";
  
  resolveValue = stack: context: renderer: value: arg:
    let
      stackPath' = builtins.map (v: v.tag) stack;
      stackPath = formatTagPath ([context] ++ stackPath');
      funcResult = coerceValue stackPath (value arg);
      finalResult = if builtins.isFunction value then renderer funcResult stack else coerceValue stackPath value;
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
      else if index >= builtins.length list then
        throw "Close tag not found (expected close of ${formatTagPath stack})"
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

  handleElements = renderer: list: stack:
    let
      head = builtins.head list; 
    in
      if list == [] then ""
      else if isTag head then handleTag renderer list head stack
      else head + (handleElements renderer (builtins.tail list) stack);

  handleTag = renderer: list: elem: stack:
    let
      mod = elem.modifier;
      tag = elem.tag;
      val = findVariableValue tag stack;
      isFalsyVal = val == null || val == false || val == [];
      openLeading = elem.effectiveLeadingSpace;
      openTrailing = elem.effectiveTrailingSpace;
      remainder = handleElements renderer (builtins.tail list) stack;
      resolver = resolveValue stack tag;
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
          partialRendered = defaultRenderer partialTemplateFinal stack;
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
               (builtins.foldl' (acc: itVal:
                 let
                   sectionResult = handleElements renderer sectionList ((stackElement tag itVal) ++ stack);
                   sectionRawResult = builtins.foldl' (a: v: a + (if isTag v then v.initialText else v)) "" sectionList;
                   resolvedValue = if builtins.isFunction itVal then resolver renderer itVal sectionRawResult else sectionResult;
                 in
                   acc + openTrailing + resolvedValue + endLeading)
                 openLeading effectiveValue) + endTrailing
          ) + (handleElements renderer afterSectionList stack)
      else if mod == ESCAPED || mod == UNESCAPED || mod == UNESCAPED2 then
        let
          resolvedValue = resolver defaultRenderer val null;
          escapedValue = if mod == ESCAPED then cfg.escape resolvedValue else resolvedValue;
        in
          openLeading + escapedValue + openTrailing + remainder
      else
        throw "Unknown modifier: ${mod}";
  
  prepareChunks = rawList:
    let
      cleanedList = builtins.filter (e: e != "") rawList;
      canBeStandalone = mod:
        mod == SECTION || mod == INVERT || mod == COMMENT || mod == CLOSE || mod == PARTIAL;
      
      tagsToAttrs = list: idx: element:
        if builtins.isList element then
          let
            at = builtins.elemAt element;
            initialText = at 0;
            leadingSpace = at 1;
            modifier = at 2;
            tag = utils.strip (at 3);
            baseTrailingSpace = at 4;
            trailingLf = at 5;

            hasLeadingLf = let
              endsWithLf = s: s != null && ((strings.hasSuffix "\n" s) || (strings.hasSuffix "\r\n" s));
              elemEndsWithLf = e: if builtins.isList e then endsWithLf (builtins.elemAt e 5) else endsWithLf e;
              prevEl = builtins.elemAt list (idx - 1);
            in
              idx == 0 || (elemEndsWithLf prevEl);

            isStandalone = (canBeStandalone modifier) && trailingLf != null && hasLeadingLf;
            trailingSpace = baseTrailingSpace + (utils.nullToEmpty trailingLf);
          in {
            inherit tag modifier leadingSpace trailingSpace isStandalone initialText;
            effectiveLeadingSpace = if isStandalone then "" else leadingSpace;
            effectiveTrailingSpace = if isStandalone then "" else trailingSpace;
          }
        else
          element;
    in
      lists.imap0 (tagsToAttrs cleanedList) cleanedList;

  renderWithConstantDelimiters = delimiterStart: delimiterEnd: template: stack: 
    let
      renderer = renderWithConstantDelimiters delimiterStart delimiterEnd;
      delimiterStartEscaped = strings.escapeRegex delimiterStart;
      delimiterEndEscaped = strings.escapeRegex delimiterEnd;
      tagExcludeChar = strings.escapeRegex (builtins.substring 0 1 delimiterEnd);
      splitRe = "(([[:blank:]]*)" + delimiterStartEscaped + "([#/!&^{>]?)([^" + tagExcludeChar + "]+)}?" + delimiterEndEscaped + "([[:blank:]]*)($|\n|\r\n)?)";
      splited = builtins.split splitRe template;
      matches = prepareChunks splited;
    in
      handleElements renderer matches stack;

  # Split template in chunks with different delimiters 
  renderWithDynamicDelimiters = delimiterStart: delimiterEnd: template: stack: 
    let
      delimiterStartEscaped = strings.escapeRegex delimiterStart;
      delimiterEndEscaped = strings.escapeRegex delimiterEnd;
      splitRe = "((^|\n|\r\n)?([[:blank:]]*)" + delimiterStartEscaped +
                "=[[:blank:]]*([^[:blank:]]+)[[:blank:]]+([^[:blank:]{]+)[[:blank:]]*=" +
                delimiterEndEscaped + "([[:blank:]]*)($|\n|\r\n)?)";
      splited = builtins.split splitRe template;
      
      count = builtins.length splited;
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
      
      renderedWithOriginalDelimiters = renderWithConstantDelimiters delimiterStart delimiterEnd (builtins.head splited) stack;
      renderedWithNewDelimiters = spacing + (renderWithDynamicDelimiters newDelimiterStart newDelimiterEnd partWithNewDelimiters stack);
    in
      renderedWithOriginalDelimiters + 
      (if count == 1 then "" 
       else if count > 2 then renderedWithNewDelimiters
       else throw "Unexpected number of parts: ${toString count}")
  ;

  stackElement = tag: value: [{ inherit tag value; }];
  defaultRenderer = renderWithDynamicDelimiters DEFAULT_DELIMITER_START DEFAULT_DELIMITER_END;

  renderTemplate = template: view:
    let
      templateContent = if builtins.isPath template then builtins.readFile template else template;
    in
      defaultRenderer templateContent (stackElement "" view);
in renderTemplate template view

        
