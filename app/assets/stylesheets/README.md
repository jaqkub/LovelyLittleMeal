# Stylesheets Organization

This directory follows Rails and SCSS best practices for organizing stylesheets.

## Directory Structure

```
app/assets/stylesheets/
├── application.scss          # Main entry point - only imports
├── config/                   # Configuration and variables
│   ├── _fonts.scss
│   ├── _colors.scss
│   └── _bootstrap_variables.scss
├── components/               # Component-specific styles
│   ├── _index.scss           # Imports all components
│   ├── _alert.scss
│   ├── _avatar.scss
│   ├── _buttons.scss         # All button variants
│   ├── _chat.scss            # Chat interface and messages
│   ├── _forms.scss           # Form inputs and checkboxes
│   ├── _recipe.scss          # Recipe cards and details
│   └── _form_legend_clear.scss
├── layouts/                   # Layout-specific styles
│   ├── _main.scss            # Main layout, body, html
│   └── _navbar.scss          # Navigation bar
├── utilities/                 # Utility classes and helpers
│   └── _animations.scss      # Keyframe animations
├── base/                     # Base styles (currently empty, reserved for future use)
├── pages/                    # Page-specific styles (currently empty, reserved for future use)
└── custom.scss               # Legacy file (now empty, kept for backwards compatibility)
```

## Import Order in `application.scss`

The import order follows a logical cascade:

1. **Config** - Variables and configuration that other files depend on
2. **External Libraries** - Bootstrap, Font Awesome, etc.
3. **Layouts** - Global layout styles
4. **Utilities** - Reusable utility classes
5. **Components** - Component-specific styles
6. **Legacy** - Custom overrides (if needed)

## Where to Add New Styles

### Components (`components/`)
Add styles for reusable UI components:
- Buttons, cards, forms, modals, etc.
- Create a new `_component-name.scss` file
- Import it in `components/_index.scss`

### Layouts (`layouts/`)
Add styles for page structure:
- Header, footer, sidebar, main content areas
- Grid systems, containers
- Create a new `_layout-name.scss` file
- Import it in `application.scss`

### Utilities (`utilities/`)
Add reusable utility classes:
- Animations, helpers, mixins
- Create a new `_utility-name.scss` file
- Import it in `application.scss`

### Pages (`pages/`)
Add page-specific styles (use sparingly):
- Styles that only apply to one specific page
- Create a new `_page-name.scss` file
- Import it in `application.scss`

## Naming Conventions

- Use BEM-like naming for components (e.g., `.recipe-card`, `.recipe-card-body`)
- Use descriptive names that indicate purpose
- Prefix component files with underscore (`_`) for SCSS partials
- Use kebab-case for file names

## Migration Notes

All styles have been migrated from the original `application.scss` and `custom.scss` files into organized component, layout, and utility files. The original files have been cleaned up to only contain imports.

