# Markdown horizontal-region retention

The iOS reader retires settled offscreen code/table labels while retaining their horizontal scroll containers, content width/height and table spacing. Ordinary prose and its full selection layout remain mounted. A prefetch band covers the viewport plus one screen above and below. Text building, inline styling and syntax tokenization must report ready, and geometry must stay stable for 250 ms before a label retires. Remounting retains the cached extent until new content is ready, preventing horizontal offsets from clamping against an initially empty label.

Active selection keeps content mounted through the existing selection coordinator. VoiceOver, Switch Control, Speak Screen and AssistiveTouch use the eager rendering path. Content revisions, viewport width and the text environment remount labels for measurement. The opt-in is iOS-only; Source and image loading continue through their existing paths.

This is a reduction in retained rich content while browsing. It does not eliminate initial full measurement, bound cold lifetime peak memory, establish physical-device memory safety, or claim first pixels, sub-200-ms display or hitch-free rendering. Final measurements and signed Simulator/actual VoiceOver evidence are retained with the verification task.

`OverflowViewportTests` checks exact document/region dimensions and retained horizontal offsets through retirement/remount, unchanged full prose copy attributes, active offscreen code selection and copy, and remeasurement of updated offscreen code. Existing reading-position, relative-link, Source/Rendered, image and VoiceOver tests remain applicable.
