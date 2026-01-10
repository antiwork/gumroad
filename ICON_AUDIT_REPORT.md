# Gumroad Icon Audit Report

Generated: 2025-01-10

## Summary

| Metric | Count | Percentage |
|--------|-------|------------|
| Total Icons | 186 | 100% |
| **Used Icons** | 114 | 61% |
| **Unused Icons** | 77 | 41% |

## Recommendation

Consider removing unused icons to reduce bundle size and simplify maintenance.
Potential savings: ~77 SVG files (~150-300KB depending on complexity).

## Unused Icons (77)

These icons exist in `app/assets/images/icons/` but are not referenced in any `.tsx`, `.ts`, `.scss`, `.css`, or `.erb` file:

| Icon | Potential Use Case |
|------|-------------------|
| arrow-counterclockwise | Undo/refresh |
| arrows-collapse | Collapse UI |
| arrows-expand | Expand UI |
| bar-chart-fill | Analytics |
| bold | Rich text editor |
| book / book-half | Documentation |
| brush | Design tools |
| bullseye | Targeting |
| camera-video / camera-video-fill | Video |
| camera2 | Photos |
| chat-right-text-fill | Messaging |
| check-square | Checkboxes |
| code | Code blocks |
| cup2 | Coffee/tips |
| deal-fill | Deals |
| diagram-2-fill | Diagrams |
| embed | Embeds |
| emoji-smile | Emojis |
| envelope-open-fill | Email |
| file-arrow-down | Downloads |
| file-earmark-diff | Diffs |
| file-earmark-image-fill | Images |
| file-earmark-music-fill | Audio |
| file-earmark-plus | Add file |
| file-earmark-text-fill | Documents |
| file-earmark-zip-fill | Archives |
| file-music | Music |
| file-play | Media |
| fonts | Typography |
| gift | Gifts (unused, gift-fill IS used) |
| globe | International |
| h1 / h2 / h3 | Headings |
| hdd-network-fill | Network |
| heart-fill | Favorites |
| image | Images |
| info-circle-fill | Info |
| italic | Rich text |
| key2 | Security |
| lighting-fill | Performance |
| linkedin | Social |
| mic-fill | Audio recording |
| music-note-beamed | Music |
| ordered-list | Lists |
| outline-check-circle | Success |
| outline-check-circle-about | About |
| outline-circle-play | Play |
| outline-dots-circle-horizontal | More options |
| outline-drag-vert | Vertical drag |
| outline-mail-open | Read email |
| outline-menu | Menu |
| outline-shopping-bag | Shopping |
| person-plus-fill | Add user |
| person-x-fill | Remove user |
| phone | Phone |
| quote / quote-squared | Quotes |
| redo | Redo |
| save | Save |
| scissors | Cut |
| shield-exclamation | Security warning |
| shop-window-fill | Store |
| solid-chat-alt | Chat |
| solid-cog | Settings |
| solid-database | Database |
| solid-flag | Flag |
| solid-hand | Stop |
| solid-user | User |
| soundwave | Audio |
| stickies | Notes |
| strikethrough | Rich text |
| underline | Rich text |
| undo | Undo |
| volume-down | Volume |

## Used Icons (114)

These icons are actively referenced in the codebase:

```
apple, archive, archive-fill, arrow-diagonal-up-right, arrow-down,
arrow-left, arrow-right, arrow-right-circle, arrow-right-reply, arrow-up,
arrow-up-right-square, bank, bookmark-check-fill, bookmark-fill,
bookmark-heart-fill, bookmark-plus, bookmark-x, box, box-arrow-in-right-fill,
button, calendar-all, card, card-image-fill, card-text, cart-plus,
cart3-fill, circle, circle-fill, circle-pause, circle-play, clock-history,
code-square, discord, download, download-fill, dropbox, envelope-fill,
eye-fill, file-earmark-binary-fill, file-earmark-font, file-earmark-medical,
file-earmark-medical-fill, file-earmark-play-fill, file-earmark-text,
file-text, file-text-fill, files-earmark, filter, folder-plus, gear,
gear-fill, gift-fill, google, grid, half-star, horizontal-rule,
info-circle, input-cursor-text, link, lock-fill, media, outline-bell,
outline-check, outline-cheveron-down, outline-cheveron-left,
outline-cheveron-right, outline-cheveron-up, outline-clock,
outline-credit-card, outline-currency-dollar, outline-drag,
outline-duplicate, outline-key, outline-refresh, outline-star, paperclip,
paypal, pencil, people-fill, person, person-circle-fill, plus, share,
shop-window, size, skip-back-15, skip-forward-30, solid-bell,
solid-check-circle, solid-currency-dollar, solid-document-text,
solid-folder-open, solid-key, solid-search, solid-send,
solid-shield-exclamation, solid-star, sparkle, stack-fill, stripe,
three-dots, trash2, truck, twitter, unordered-list, upload-fill, x,
x-circle, x-circle-fill, x-square, zoom-in, zoom-out
```

## Methodology

Scanned all files matching:
- `app/javascript/**/*.tsx`
- `app/javascript/**/*.ts`
- `app/javascript/**/*.scss`
- `app/javascript/**/*.css`
- `app/views/**/*.erb`

Patterns searched:
- `<Icon name="..." />`
- `icon-{name}` class references
