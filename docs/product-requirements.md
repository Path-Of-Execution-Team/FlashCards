# FlashCards Product Brief

## Document Purpose

This document gathers the agreed business, product, and functional assumptions for the FlashCards application. It is meant to serve as a single source of truth for the backend, GUI, hosted services, and further product planning.

## Product Vision

FlashCards is an application for learning material using the Leitner method. The user can:

- use community decks,
- create their own decks,
- study through intelligently generated sessions,
- track their progress,
- return to learning through reminders and personal settings.

The product should eventually combine:

- spaced repetition based learning,
- a simple and fast content creation flow,
- social features,
- a clear progress dashboard,
- a well-organized development workflow for future growth.

## Business Goals

- Build an application for regular vocabulary and knowledge learning based on the Leitner method.
- Let users start learning quickly without manually planning reviews.
- Offer both community content and private content.
- Maintain study consistency through reminders, the dashboard, and easy return to the active deck.
- Grow the product into a platform for creating, discovering, and rating educational decks.

## User Groups

- Individual users learning languages.
- Users learning theory, definitions, dates, and any fact-based material.
- Deck creators who want to publish content for others.
- In the future, moderators or administrators responsible for content quality.

## Main Value Proposition

- The system plans study sessions automatically.
- The user can start from a ready-made deck or create their own right away.
- Deck creation is easy through a form or CSV import.
- Learning supports two answer modes: `ABCD` and `open answer`.
- The application shows progress, deck status, and the amount of material still left to study.

## Key User Scenarios

1. The user creates an account with email, username, and password, or signs in with Google or Discord.
2. If they register with email, they confirm the account using a verification code sent by email.
3. The user can recover access through the forgot password flow.
4. The user can change the application language, email, password, study preferences, and notification preferences.
5. The user browses the deck catalog, filters decks, saves favorites, and returns to recently used decks.
6. The user can preview a deck before subscribing.
7. The user can subscribe to a deck and manage it from a dedicated panel.
8. The user can create their own deck, add a description, tags, and content manually or through CSV.
9. Before studying, the backend generates a session based on the Leitner method.
10. The user answers either in `ABCD` mode or by typing the answer manually.
11. The system updates progress and future review dates.
12. The user sees a homepage dashboard with stats and a deck catalog.
13. The user can rate community decks.
14. In later stages, the user can use comments, author profiles, rich content, and AI features.

## Functional Scope

### 1. Accounts and Identity

- Standard registration: `email`, `username`, `password`.
- Standard login with email or username and password.
- Social login with Google.
- Social login with Discord.
- Multiple login methods linked to a single user profile.

### 2. Account Security

- Account verification using a code sent by email after standard registration.
- Resending the verification code.
- Password reset by email.
- Email change with re-verification of the new address.
- Password change after providing the current password.

### 3. Account and Application Settings

- Changing the application language.
- Changing the email address.
- Changing the password.
- Study preferences and daily limits.
- Reminder preferences and notification hours.
- Configuration of default intervals and reminder channels.

### 4. Decks and Catalog

- Two deck source types:
  - community decks,
  - private decks.
- A deck should contain:
  - title,
  - description,
  - tags,
  - author,
  - public or private status,
  - average rating,
  - number of ratings.
- The deck catalog should support:
  - search,
  - filtering,
  - preview before subscription,
  - favorites,
  - recently used.

### 5. Deck Creation

- A dedicated panel for creating and editing decks.
- Adding a title, description, and tags.
- Adding flashcards manually through a form.
- Importing flashcards from CSV.
- In later stages:
  - Excel import,
  - Google Sheets import,
  - deck export,
  - archiving,
  - duplication,
  - sharing owned decks.

### 6. Flashcards and Material Types

- Each flashcard has a question, a correct answer, and optional choices for `ABCD` mode.
- The system supports:
  - `multiple choice (ABCD)`,
  - `open answer`.
- In later stages, a flashcard may include:
  - an image,
  - audio,
  - synonyms and minor typo tolerance.

### 7. Active Deck Management Panel

- Deck subscription and unsubscription.
- A view showing how much material is still left to study.
- A view showing how much material has already been mastered.
- A list of learned words or materials.
- Entering the study flow directly from the panel.

### 8. Leitner System and Study Sessions

- The backend stores the state of every flashcard per user.
- For each flashcard, the system stores at least:
  - Leitner box,
  - date of the last answer,
  - date of the next review,
  - correct answer streak,
  - number of attempts.
- Example logic:
  - a correct answer moves the card to the next box,
  - a wrong answer resets or lowers the box,
  - the next review interval depends on the box.
- The backend generates daily sessions based on:
  - overdue reviews,
  - the limit of new cards,
  - the review limit,
  - user settings,
  - the selected deck or decks.

### 9. Homepage Dashboard

- User study statistics.
- Current study streak in days.
- Record for the longest correct-answer streak without mistakes.
- A deck catalog section for discovery.

### 10. Notifications

- Email reminders.
- Push notifications.
- Configurable reminder hours.
- Hosted services prepare sessions and send reminders according to user preferences.

### 11. Social Features

- Ratings for community decks.
- In later stages:
  - comments,
  - author profiles,
  - author libraries,
  - following authors,
  - deck rankings,
  - reporting incorrect or low-quality decks.

### 12. Moderation and Administration

- `admin` and `moderator` roles.
- Review of reported decks.
- Moderation decision history.
- Product reports and event logging.

### 13. AI and Smart Features

- Generating flashcards from text or PDF.
- Generating `ABCD` answers.
- Explanations after wrong answers.
- Deck recommendations.
- Smart repeat for difficult words.

## Non-Functional Requirements

- Progress data must be calculated per user and per flashcard.
- The session algorithm must not lose overdue reviews.
- The system must support at least `pl` and `en`.
- Notifications must respect user preferences.
- Social login must not duplicate accounts when the same email is already in use.
- Imports and exports must provide clear validation and error reporting.
- The dashboard and study flow must work well on desktop and mobile.

## Default Product Settings

- Review hour: `18:00`.
- Daily limit of new flashcards: `20`.
- Daily review limit: `100`.
- Number of Leitner boxes: `5`.
- Example intervals: `1, 2, 4, 7, 14 days`.
- Default reminder channel: email enabled, push disabled.
- Default study mode: selected before the session starts.

## Extended Domain Model

- `User`
- `AuthIdentity`
- `EmailVerificationToken`
- `PasswordResetToken`
- `UserPreferences`
- `NotificationPreference`
- `NotificationEvent`
- `Deck`
- `DeckTag`
- `DeckRating`
- `DeckComment`
- `DeckReport`
- `FavoriteDeck`
- `RecentlyUsedDeck`
- `Flashcard`
- `FlashcardOption`
- `FlashcardMedia`
- `UserDeckEnrollment`
- `UserFlashcardProgress`
- `StudySession`
- `StudySessionItem`
- `AuditEvent`

## Module Responsibilities

### FlashCardsBackend

- local auth and social auth,
- account verification,
- password reset,
- deck and flashcard CRUD,
- CSV import and future imports,
- Leitner session generator,
- dashboard API,
- active deck management API,
- ratings API and social feature APIs,
- user settings API,
- event log and reporting.

### FlashCardsHostedServices

- reminder scheduler,
- email delivery,
- push notification triggers,
- verification code delivery,
- password reset email delivery,
- session preparation before planned study time.

### FlashCardsGUI

- onboarding and auth,
- account verification flow,
- password reset flow,
- homepage dashboard,
- catalog and discovery,
- deck creation panel,
- active deck management panel,
- study screen,
- account and application settings,
- social features,
- rich content and AI UI in later stages.

## Product Roadmap

### Milestone: Auth & Account

- local registration,
- local login,
- Google and Discord login,
- email verification,
- password reset,
- email change,
- password change,
- account settings.

### Milestone: Decks & Content

- deck creation,
- tags, description, and status,
- manual flashcard creation,
- CSV import,
- export,
- rich content.

### Milestone: Learning & Progress

- Leitner model,
- session generation,
- answer processing,
- active deck panel,
- deck progress,
- mastered words,
- statistics.

### Milestone: Homepage & Discovery

- dashboard,
- catalog,
- search,
- filters,
- favorites,
- recently used,
- deck preview.

### Milestone: Notifications & Settings

- review settings,
- reminders,
- hosted scheduler,
- notification hours.

### Milestone: Social & Moderation

- ratings,
- comments,
- author profiles,
- rankings,
- reporting content,
- moderator panel.

### Milestone: AI & Smart Features

- flashcard generation,
- `ABCD` answer generation,
- explainers,
- recommendations,
- smart repeat.

### Milestone: Admin & Analytics

- admin and moderator roles,
- event log,
- product reports,
- basic A/B testing.

## Delivery Priorities

### MVP

- local and social auth,
- email verification and password reset,
- account and application settings,
- deck CRUD,
- deck creation panel,
- CSV import,
- Leitner model,
- study sessions,
- active deck management panel,
- homepage dashboard,
- deck ratings,
- reminder scheduler.

### MVP+1

- discovery and search,
- favorites and recently used,
- comments and author profiles,
- rich content,
- export and additional imports,
- synonyms and typo tolerance,
- moderator role and review panel.

### V2

- AI generation,
- recommendations,
- smart repeat,
- product reports,
- A/B experiments,
- more advanced administrative tools.

## Current Repository State vs Target Product

- The repository has a foundation for local auth and basic auth frontend screens.
- The agreed backlog already covers MVP and post-MVP expansion.
- GitHub Issues, Type, Milestones, and Projects are organized for further execution.
- The product is planned much wider than the current implementation state, but the roadmap and work breakdown are already prepared.

## Most Reasonable Next Step

The most reasonable next step is to implement a vertical MVP slice:

1. `Deck`
2. `Flashcard`
3. `UserDeckEnrollment`
4. `UserFlashcardProgress`
5. `StudySession`
6. `Dashboard`
7. `Deck management panel`

This will unblock the backend, GUI, hosted services, and the first end-to-end tests at the same time.
