# Agentic Workflow Implementation Plan

## Overview

This document provides a detailed, step-by-step implementation plan for migrating from the current prompt-based recipe generation system to the new agentic workflow architecture.

## Implementation Strategy

We'll implement in phases, starting with critical tools that fix immediate issues, then building out the full workflow. Each phase is designed to be independently testable and deployable.

---

## Phase 1: Critical Tools & Foundation (Week 1)

### Step 1.1: Create Tool Base Infrastructure
**Goal**: Set up the foundation for all tools

**Tasks**:
1. Create `app/lib/tools/` directory structure
2. Create base tool module/concern if needed
3. Set up tool testing infrastructure
4. Create tool error classes

**Files to Create**:
- `app/lib/tools/base_tool.rb` (optional base class)
- `app/lib/tools/errors.rb` (tool-specific errors)
- `spec/lib/tools/` (test directory)

**Acceptance Criteria**:
- [ ] Directory structure exists
- [ ] Tool error classes defined
- [ ] Test infrastructure ready

---

### Step 1.2: Implement AllergenWarningValidator Tool
**Goal**: Fix the critical warning emoji issue with programmatic validation

**Tasks**:
1. Create `AllergenWarningValidator` tool class
2. Implement validation logic (check for emoji, personalized text, position)
3. Write comprehensive tests
4. Integrate into current flow (run after recipe generation, log violations)

**Files to Create**:
- `app/lib/tools/allergen_warning_validator.rb`
- `spec/lib/tools/allergen_warning_validator_spec.rb`

**Implementation Details**:
- Pure Ruby validation (no LLM call)
- Check instruction steps (not description) for warning emoji (⚠️)
- Verify warning mentions specific allergen from user's list
- Check warning is in the same instruction step where allergen is added (or adjacent steps)
- Verify warning format: "⚠️ WARNING:" (capitalized) at beginning of instruction
- Return structured violation report with fix instructions

**Status**: ✅ **COMPLETED** (Updated to check instructions instead of description)

**Acceptance Criteria**:
- [x] Tool validates warning presence correctly
- [x] Tool detects missing emoji
- [x] Tool detects generic vs personalized warnings
- [x] Tool provides specific fix instructions
- [x] All tests pass
- [x] Integrated into current flow (logging violations)
- [x] Updated to check instructions array instead of description field

---

### Step 1.3: Implement IntentClassifier Tool
**Goal**: Reliably classify user intent to determine execution path

**Tasks**:
1. Create `IntentClassifier` tool class extending `RubyLLM::Tool`
2. Define tool parameters (user message, conversation history, recipe state)
3. Implement classification logic using GPT-5-nano
4. Define output schema for classification result
5. Write tests with mocked LLM responses
6. Integrate into current flow (run before recipe generation)

**Files to Create**:
- `app/lib/tools/intent_classifier.rb`
- `spec/lib/tools/intent_classifier_spec.rb`

**Implementation Details**:
- Use `RubyLLM::Tool` base class
- Model: `gpt-4.1-nano` (changed from gpt-5-nano for better performance)
- Input: message, conversation history, current recipe
- Output: `{ intent: string, confidence: float, detected_url: string | nil, reasoning: string }`
- Classification categories: first_message_link, first_message_free_text, first_message_complete_recipe, first_message_query, question, modification, clarification

**Status**: ✅ **COMPLETED**

**Acceptance Criteria**:
- [x] Tool correctly classifies all intent types
- [x] Tool detects URLs in messages
- [x] Tool provides confidence scores
- [x] All tests pass
- [x] Integrated into current flow (runs before recipe generation)

---

### Step 1.4: Implement ConversationContextAnalyzer Tool
**Goal**: Analyze conversation history to determine message structure

**Tasks**:
1. Create `ConversationContextAnalyzer` tool class
2. Implement context analysis using GPT-5-nano
3. Define output schema
4. Write tests
5. Integrate into current flow

**Files to Create**:
- `app/lib/tools/conversation_context_analyzer.rb`
- `spec/lib/tools/conversation_context_analyzer_spec.rb`

**Implementation Details**:
- Use `RubyLLM::Tool` base class
- Model: `gpt-4.1-nano` (changed from gpt-5-nano for better performance)
- Input: conversation history
- Output: `{ is_first_message: boolean, previous_topics: array, recent_changes: array, conversation_tone: string, greeting_needed: boolean }`

**Status**: ✅ **COMPLETED**

**Acceptance Criteria**:
- [x] Tool correctly identifies first messages
- [x] Tool determines greeting necessity
- [x] Tool tracks conversation context
- [x] All tests pass
- [x] Integrated into current flow

---

### Step 1.5: Implement RecipeLinkExtractor Tool
**Goal**: Extract recipe content from URLs (web scraping)

**Tasks**:
1. Create `RecipeLinkExtractor` tool class
2. Implement web scraping (HTTP client, HTML parsing)
3. Implement recipe extraction (structured data, pattern matching, LLM fallback)
4. Handle errors gracefully
5. Write tests (with mocked HTTP responses)
6. Integrate into current flow (conditional on link intent)

**Files to Create**:
- `app/lib/tools/recipe_link_extractor.rb`
- `spec/lib/tools/recipe_link_extractor_spec.rb`

**Dependencies**:
- Add `nokogiri` gem for HTML parsing (if not already present)
- Add `faraday` gem for HTTP client (if not already present)

**Implementation Details**:
- Pure Ruby + optional LLM fallback
- Try structured data (JSON-LD, microdata) first
- Fall back to pattern matching for common sites
- Use GPT-4.1-nano as last resort for unstructured HTML (changed from gpt-5-nano)
- Return structured recipe data

**Status**: ✅ **COMPLETED**

**Acceptance Criteria**:
- [x] Tool fetches URLs successfully
- [x] Tool extracts recipe data from common sites
- [x] Tool handles errors gracefully
- [x] Tool uses LLM fallback when needed
- [x] All tests pass
- [x] Integrated into current flow (runs when link detected)

---

### Step 1.6: Update RecipesController to Use Phase 1 Tools
**Goal**: Integrate Phase 1 tools into current workflow

**Tasks**:
1. Update `process_prompt` method to use IntentClassifier
2. Add ConversationContextAnalyzer call
3. Add conditional RecipeLinkExtractor call
4. Add AllergenWarningValidator call (logging only for now)
5. Update message generation to use context from ConversationContextAnalyzer
6. Write integration tests

**Files to Modify**:
- `app/controllers/recipes_controller.rb`

**Files to Create**:
- `spec/requests/recipes_spec.rb` (if not exists, or update existing)

**Status**: ✅ **COMPLETED**

**Additional Work Completed**:
- Performance timing logs added to all phases
- Model optimization: Changed from gpt-5-nano/gpt-5-mini to gpt-4.1-nano/gpt-4o for better performance
- Image generation strategy pattern implemented (real vs stub)
- Allergies refactored from text to JSONB hash format with standard allergy list
- System prompt updated to require warnings in instruction steps (not description)

**Acceptance Criteria**:
- [x] Intent classification works in controller
- [x] Link extraction works when URL detected
- [x] Warning validation runs and logs violations
- [x] Context analysis influences message generation
- [x] All existing tests still pass
- [x] Performance timing implemented
- [x] Image generation strategy pattern implemented

---

## Phase 1 Status: ✅ COMPLETED

All Phase 1 tools have been implemented and integrated. Recent updates:
- AllergenWarningValidator now checks instruction steps (not description)
- All models optimized: gpt-4.1-nano for tools, gpt-4o for recipe generation
- Image generation uses strategy pattern (real/stub)
- Allergies stored as JSONB hash with standard allergy list
- Performance timing logs added throughout

**Known Issues**:
- Validation detects violations but doesn't automatically fix them (Phase 3 will address this)
- System prompt updated but LLM sometimes still puts warnings in description instead of instructions

---

## Phase 2: Validation Suite (Week 2)

### Step 2.1: Implement ApplianceCompatibilityChecker Tool
**Goal**: Verify recipe uses only available appliances

**Tasks**:
1. Create tool class
2. Implement appliance checking logic using GPT-4.1-nano
3. Return violations with specific steps
4. Write tests
5. Integrate into validation phase

**Files Created**:
- `app/lib/tools/appliance_compatibility_checker.rb` ✅
- `spec/lib/tools/appliance_compatibility_checker_spec.rb` (tests pending)

**Files Modified**:
- `app/controllers/recipes_controller.rb` ✅

**Status**: ✅ **COMPLETED** (Implementation done, tests pending)

**Implementation Details**:
- Uses GPT-4.1-nano for fast appliance detection in instructions
- Detects both direct mentions and implied usage (e.g., "bake" implies oven)
- Handles alternative names (e.g., "stovetop" = "stove")
- Falls back to pattern matching if LLM fails
- Integrated into unified `validate_recipe` method alongside allergen validation
- Violations are aggregated and fixed together

**Acceptance Criteria**:
- [x] Tool detects appliance violations
- [x] Tool provides specific fix instructions
- [x] Integrated into validation phase
- [ ] All tests pass (tests pending)

---

### Step 2.2: Implement IngredientAllergyChecker Tool
**Goal**: Cross-reference ingredients against user allergies

**Tasks**:
1. Create tool class
2. Implement ingredient matching logic (pure Ruby)
3. Handle edge cases (peanuts vs nuts, etc.)
4. Provide substitute suggestions
5. Write tests
6. Integrate into validation phase

**Files Created**:
- `app/lib/tools/ingredient_allergy_checker.rb` ✅
- `spec/lib/tools/ingredient_allergy_checker_spec.rb` (tests pending)

**Files Modified**:
- `app/controllers/recipes_controller.rb` ✅

**Status**: ✅ **COMPLETED** (Implementation done, tests pending)

**Implementation Details**:
- Uses pure Ruby validation (no LLM call) for 100% reliability
- Checks all ingredients against user's active allergies
- Handles edge cases with allergen-to-ingredient mappings (e.g., "peanut" matches "peanuts", "peanut butter", etc.)
- Distinguishes between explicitly requested allergens (handled by AllergenWarningValidator) vs unexpected allergens (should be removed/substituted)
- Provides substitute suggestions for each detected allergen
- Filters substitute suggestions to avoid recommending allergens the user is also allergic to
- Integrated into unified `validate_recipe` method alongside other validators
- Violations are aggregated and fixed together

**Acceptance Criteria**:
- [x] Tool detects allergen violations
- [x] Tool handles edge cases correctly (peanuts vs tree_nuts, etc.)
- [x] Tool suggests substitutes
- [x] Integrated into validation phase
- [ ] All tests pass (tests pending)

---

### Step 2.3: Implement MetricUnitValidator Tool
**Goal**: Ensure all quantities use metric units and shopping list has realistic purchase amounts

**Tasks**:
1. Create tool class
2. Implement regex/pattern matching for non-metric units
3. Provide automatic conversions
4. Validate shopping list for realistic purchase amounts
5. Write tests
6. Integrate into validation phase

**Files Created**:
- `app/lib/tools/metric_unit_validator.rb` ✅
- `spec/lib/tools/metric_unit_validator_spec.rb` (tests pending)

**Files Modified**:
- `app/controllers/recipes_controller.rb` ✅
- `app/services/recipe_fix_service.rb` ✅

**Status**: ✅ **COMPLETED** (Implementation done, tests pending)

**Implementation Details**:
- Uses pure Ruby validation (no LLM call) for 100% reliability
- Converts non-metric units to metric (cups -> ml, teaspoons -> ml, ounces -> g, etc.)
- Validates shopping list for realistic purchase amounts:
  - Removes unrealistic small amounts (e.g., "2g black pepper" -> "black pepper")
  - Converts "1 clove garlic" to "1 head garlic"
  - Converts "1 teaspoon olive oil" to "250ml olive oil"
  - Removes teaspoons, pinches, dashes, cloves from shopping list
- Applies conversions programmatically (no LLM call needed)
- Integrated into unified `validate_recipe` method
- System prompt updated with clear shopping list requirements

**Acceptance Criteria**:
- [x] Tool detects non-metric units
- [x] Tool provides conversions
- [x] Tool validates shopping list for realistic amounts
- [x] Conversions applied programmatically
- [x] Integrated into validation phase
- [ ] All tests pass (tests pending)

---

### Step 2.4: Implement RecipeCompletenessChecker Tool
**Goal**: Validate recipe has all required fields

**Tasks**:
1. Create tool class
2. Implement completeness checks using GPT-5-nano
3. Check ingredients match instructions
4. Check shopping list matches ingredients
5. Write tests
6. Integrate into validation phase

**Files to Create**:
- `app/lib/tools/recipe_completeness_checker.rb`
- `spec/lib/tools/recipe_completeness_checker_spec.rb`

**Acceptance Criteria**:
- [ ] Tool detects missing fields
- [ ] Tool detects mismatches
- [ ] All tests pass

---

### Step 2.5: Implement PreferenceComplianceChecker Tool
**Goal**: Verify recipe aligns with user preferences

**Tasks**:
1. Create tool class
2. Implement preference checking using GPT-5-nano
3. Return compliance report
4. Write tests
5. Integrate into validation phase

**Files to Create**:
- `app/lib/tools/preference_compliance_checker.rb`
- `spec/lib/tools/preference_compliance_checker_spec.rb`

**Acceptance Criteria**:
- [ ] Tool detects preference violations
- [ ] Tool provides specific feedback
- [ ] All tests pass

---

### Step 2.6: Implement Parallel Validation Execution
**Goal**: Run all validations concurrently using Async

**Tasks**:
1. Add `async` gem to Gemfile
2. Create validation orchestrator service
3. Implement parallel execution using Async
4. Aggregate validation results
5. Write tests
6. Integrate into controller

**Files to Create**:
- `app/services/recipe_validator.rb` (orchestrator)
- `spec/services/recipe_validator_spec.rb`

**Files to Modify**:
- `Gemfile` (add async gem)
- `app/controllers/recipes_controller.rb`

**Acceptance Criteria**:
- [ ] All validations run in parallel
- [ ] Results are aggregated correctly
- [ ] Performance improvement measured
- [ ] All tests pass

---

## Phase 3: Validation Loop & Fix Mechanism (Week 2-3)

### Step 3.1: Implement Validation Loop with Fix Mechanism
**Goal**: Automatically fix recipe violations before returning

**Tasks**:
1. Create fix loop service
2. Aggregate violations into structured feedback
3. Send violations to GPT-5-mini with fix instructions
4. Re-run validations after fixes
5. Implement max iteration limit (3)
6. Write tests
7. Integrate into controller

**Files Created**:
- `app/services/recipe_fix_service.rb` ✅
- `spec/services/recipe_fix_service_spec.rb` (tests pending)

**Files Modified**:
- `app/controllers/recipes_controller.rb` ✅

**Status**: ✅ **COMPLETED**

**Implementation Details**:
- Hybrid approach: Programmatic fixes first (fast, reliable, free), then LLM fallback for complex cases
- Programmatic fixes handle: missing_emoji, incorrect_warning_format, generic_warning
- LLM fixes handle: allergen_not_in_instructions and other complex violations
- Max 3 iterations with detailed logging
- Integrated into controller's validation phase

**Acceptance Criteria**:
- [x] Violations are fixed automatically
- [x] Loop terminates after max iterations
- [x] Allergen warnings are reliably added
- [x] Programmatic fixes work for simple violations (no LLM call needed)
- [x] LLM fixes work for complex violations
- [ ] All tests pass (tests pending)

---

### Step 3.2: Implement MessageFormatter Tool
**Goal**: Generate properly structured response messages

**Tasks**:
1. Create tool class
2. Implement message formatting using GPT-4.1-nano
3. Use conversation context to avoid greetings on follow-ups
4. Format based on actual changes made
5. Write tests
6. Integrate into controller

**Files Created**:
- `app/lib/tools/message_formatter.rb` ✅
- `app/lib/tools/message_formatter_schema.rb` ✅
- `spec/lib/tools/message_formatter_spec.rb` (tests pending)

**Files Modified**:
- `app/controllers/recipes_controller.rb` ✅

**Status**: ✅ **COMPLETED** (Implementation done, tests pending)

**Implementation Details**:
- Uses GPT-4.1-nano for fast message formatting
- Respects conversation context (greeting_needed flag)
- Formats messages based on actual changes made
- Prevents duplicate text and filler words
- Integrated into controller after validation phase
- Includes timing logs for performance monitoring

**Acceptance Criteria**:
- [x] Messages have correct structure
- [x] No greetings on follow-ups (respects conversation context)
- [x] Messages reflect actual changes
- [x] Integrated into controller
- [ ] All tests pass (tests pending)

---

### Step 3.3: Implement ImageGenerationStarter Tool
**Goal**: Trigger image generation earlier in flow

**Tasks**:
1. Create tool class
2. Implement job trigger (non-blocking)
3. Run in parallel with message formatting
4. Write tests
5. Integrate into controller

**Files to Create**:
- `app/lib/tools/image_generation_starter.rb`
- `spec/lib/tools/image_generation_starter_spec.rb`

**Files to Modify**:
- `app/controllers/recipes_controller.rb`

**Acceptance Criteria**:
- [ ] Image generation starts after validation
- [ ] Runs in parallel with message formatting
- [ ] Doesn't block response
- [ ] All tests pass

---

## Phase 4: Full Workflow Integration (Week 3)

### Step 4.1: Refactor RecipesController to Use Full Workflow
**Goal**: Complete migration to agentic workflow

**Tasks**:
1. Refactor `process_prompt` to use full workflow
2. Implement all execution paths (link, free text, modification, question)
3. Integrate parallel execution
4. Integrate validation loop
5. Integrate message formatting
6. Integrate image generation starter
7. Simplify system prompt (remove logic now in tools)
8. Write comprehensive integration tests

**Files to Modify**:
- `app/controllers/recipes_controller.rb`
- `app/controllers/recipes_controller.rb` (system_prompt method - simplify)

**Files to Create/Update**:
- `spec/requests/recipes_workflow_spec.rb` (comprehensive workflow tests)

**Acceptance Criteria**:
- [ ] All execution paths work correctly
- [ ] Parallel execution works
- [ ] Validation loop works
- [ ] System prompt is simplified
- [ ] All existing functionality preserved
- [ ] All tests pass

---

### Step 4.2: Simplify System Prompt
**Goal**: Remove logic now handled by tools

**Tasks**:
1. Remove greeting logic (now in ConversationContextAnalyzer)
2. Remove intent classification instructions (now in IntentClassifier)
3. Remove detailed validation instructions (now in tools)
4. Keep core persona and high-level workflow
5. Update RecipeSchema descriptions to be simpler
6. Test that simplified prompt still works

**Files to Modify**:
- `app/controllers/recipes_controller.rb` (system_prompt method)
- `app/lib/recipe_schema.rb` (simplify descriptions)

**Acceptance Criteria**:
- [ ] System prompt is significantly shorter
- [ ] All functionality still works
- [ ] Tools handle the logic
- [ ] Tests pass

---

### Step 4.3: Performance Optimization
**Goal**: Optimize workflow performance

**Tasks**:
1. Profile workflow execution
2. Optimize slow paths
3. Cache where appropriate
4. Optimize database queries
5. Measure and document improvements

**Acceptance Criteria**:
- [ ] Performance metrics documented
- [ ] Improvements measured
- [ ] No regressions

---

## Phase 5: Testing & Documentation (Week 3-4)

### Step 5.1: Comprehensive Test Coverage
**Goal**: Ensure all tools and workflow are thoroughly tested

**Tasks**:
1. Add missing unit tests
2. Add integration tests for all paths
3. Add edge case tests
4. Add error handling tests
5. Achieve target coverage

**Acceptance Criteria**:
- [ ] All tools have >90% coverage
- [ ] All workflow paths tested
- [ ] Edge cases covered
- [ ] Error cases covered

---

### Step 5.2: Documentation
**Goal**: Document the new workflow

**Tasks**:
1. Update README with workflow overview
2. Document each tool
3. Document workflow execution
4. Add code comments
5. Update API documentation if needed

**Files to Create/Update**:
- `README.md`
- `docs/WORKFLOW_IMPLEMENTATION.md`
- Code comments throughout

**Acceptance Criteria**:
- [ ] Documentation is complete
- [ ] Code is well-commented
- [ ] Examples provided

---

## Implementation Order

1. **Phase 1** (Critical Tools) - Fixes immediate issues
2. **Phase 2** (Validation Suite) - Comprehensive validation
3. **Phase 3** (Validation Loop) - Automatic fixes
4. **Phase 4** (Full Integration) - Complete workflow
5. **Phase 5** (Testing & Docs) - Polish and documentation

---

## Success Criteria

### Functional
- [ ] Allergen warnings appear 100% of the time when needed
- [ ] Greetings only appear on first messages
- [ ] Link pasting works correctly
- [ ] All validations run and catch violations
- [ ] Violations are automatically fixed
- [ ] All execution paths work correctly

### Performance
- [ ] Validation phase completes in <2 seconds (parallel)
- [ ] Total response time similar or better than current
- [ ] Image generation starts earlier

### Quality
- [ ] All tests pass
- [ ] Code coverage >90% for tools
- [ ] Documentation complete
- [ ] Code follows Rails conventions
- [ ] RuboCop passes

---

## Risk Mitigation

### Risks
1. **LLM API changes** - Mitigation: Use official RubyLLM documentation, version pinning
2. **Performance regressions** - Mitigation: Benchmark at each phase, optimize as needed
3. **Breaking existing functionality** - Mitigation: Comprehensive tests, gradual migration
4. **Cost increases** - Mitigation: Use GPT-5-nano for most tasks, monitor usage

### Rollback Plan
- Keep current implementation until Phase 4 complete
- Feature flag for new workflow
- Can rollback to prompt-based system if needed

---

## Next Steps

1. ✅ Phase 1 Complete - All critical tools implemented
2. **Current Priority**: Implement Phase 3.1 (Validation Loop) to automatically fix violations
3. Then proceed with Phase 2 (Validation Suite) for comprehensive validation
4. Continue with remaining phases

## Recent Updates (December 2025)

- **Model Optimization**: Switched from reasoning models (gpt-5-*) to faster models (gpt-4.1-nano, gpt-4o) for better performance
- **Allergen Warning Location**: Changed from description field to instruction steps where allergen is added
- **Allergies Storage**: Migrated from text to JSONB hash format with standard allergy list (10 allergens)
- **Image Generation**: Implemented strategy pattern for real/stub image generation
- **Performance Monitoring**: Added comprehensive timing logs for all phases

