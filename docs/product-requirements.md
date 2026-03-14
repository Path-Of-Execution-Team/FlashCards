# FlashCards Product Requirements

## Cel aplikacji

Aplikacja sluzy do nauki materialu metoda Leitnera. Uzytkownik moze korzystac z zestawow spolecznosciowych albo tworzyc wlasne fiszki, a system ma codziennie przygotowywac zestaw do nauki na podstawie postepu i ustawien uzytkownika.

## Kluczowe scenariusze uzytkownika

1. Uzytkownik zaklada konto przez email, username i haslo albo przez Google lub Discord.
2. Uzytkownik wybiera gotowy zestaw spolecznosci albo tworzy wlasny zestaw fiszek.
3. Uzytkownik uruchamia nauke i dostaje zestaw wygenerowany przez backend zgodnie z systemem Leitnera.
4. Podczas nauki odpowiada w trybie ABCD albo wpisuje odpowiedz recznie.
5. Po odpowiedzi system aktualizuje stan fiszki i wyznacza kolejna powtorke.
6. Uzytkownik otrzymuje przypomnienie o nauce przez email albo notyfikacje push, zalezne od ustawien.
7. Po zakonczeniu pracy z zestawem spolecznosciowym uzytkownik moze go ocenic.

## Zakres funkcjonalny

### 1. Konta i logowanie

- Rejestracja klasyczna: `email`, `username`, `password`.
- Logowanie klasyczne przez email lub username oraz haslo.
- Logowanie spolecznosciowe przez Google.
- Logowanie spolecznosciowe przez Discord.
- Konto powinno miec mozliwosc powiazania wielu metod logowania z jednym profilem.

### 2. Zestawy fiszek

- Dwa typy zrodel zestawow:
  - zestawy spolecznosciowe,
  - zestawy prywatne tworzone przez uzytkownika.
- Zestaw powinien miec co najmniej:
  - nazwe,
  - opis,
  - jezyk lub kategorie,
  - autora,
  - status publiczny/prywatny,
  - srednia ocene,
  - liczbe ocen.
- Przyklad zestawu: `1000 najpopularniejszych slow angielskich`.

### 3. Fiszki i tryby odpowiedzi

- Kazda fiszka ma pytanie, odpowiedz poprawna oraz opcjonalne odpowiedzi do trybu ABCD.
- System musi obslugiwac dwa tryby nauki:
  - `multiple choice (ABCD)`,
  - `open answer`, gdzie uzytkownik sam wpisuje odpowiedz.
- Tryb moze byc ustawiany na poziomie zestawu, sesji lub preferencji uzytkownika. Zalecenie MVP: ustawienie na poziomie sesji nauki.

### 4. System Leitnera

- Backend przechowuje stan kazdej fiszki per uzytkownik.
- Dla kazdej fiszki nalezy zapisac co najmniej:
  - aktualne pudelko Leitnera,
  - date ostatniej odpowiedzi,
  - date kolejnej powtorki,
  - liczbe poprawnych odpowiedzi z rzedu,
  - liczbe wszystkich podejsc.
- Przykladowa logika:
  - dobra odpowiedz przesuwa fiszke do kolejnego pudelka,
  - zla odpowiedz cofa fiszke do pierwszego pudelka albo obniza o jedno pudelko,
  - interwal kolejnej powtorki zalezy od pudelka.
- Dokladny algorytm powinien byc konfigurowalny przez ustawienia systemowe i uzytkownika.

### 5. Generowanie dziennej sesji nauki

- Przed rozpoczeciem nauki backend generuje zestaw slowek do dzisiejszej sesji.
- Generator bierze pod uwage:
  - fiszki zalegle do powtorki,
  - limit dzienny nowych fiszek,
  - limit dzienny powtorek,
  - wybrany zestaw lub zestawy,
  - preferowana godzine nauki,
  - interwaly i konfiguracje Leitnera.
- Sesja powinna byc deterministyczna dla danego dnia lub znacznika czasu, aby user nie dostawal za kazdym razem innego zestawu po odswiezeniu.

### 6. Ustawienia nauki i powiadomien

- Domyslnie system ustawia:
  - godzine powtorek,
  - liczbe dziennych slowek,
  - interwaly dla pudel Leitnera,
  - domyslny kanal przypomnien.
- Uzytkownik moze zmienic te ustawienia w opcjach.
- Uzytkownik moze wlaczyc:
  - przypomnienia email,
  - notyfikacje push.
- Uzytkownik moze wylaczyc oba kanaly przypomnien.

### 7. Oceny zestawow

- Uzytkownik moze ocenic zestaw spolecznosciowy.
- Zalecenie MVP:
  - skala `1-5`,
  - jedna aktywna ocena na uzytkownika per zestaw,
  - mozliwosc zmiany swojej oceny,
  - prezentacja sredniej i liczby ocen.

## Proponowany model domenowy

### Backend

- `User`
- `AuthIdentity`
- `Deck`
- `DeckRating`
- `Flashcard`
- `FlashcardOption`
- `UserDeckEnrollment`
- `UserFlashcardProgress`
- `StudySession`
- `StudySessionItem`
- `UserPreferences`
- `NotificationPreference`
- `NotificationEvent`

### Odpowiedzialnosc modulow

- `FlashCardsBackend`
  - auth lokalny,
  - social auth callbacki,
  - CRUD zestawow i fiszek,
  - generator sesji Leitnera,
  - API ocen,
  - API ustawien uzytkownika.
- `FlashCardsHostedServices`
  - scheduler przypomnien,
  - wysylka emaili,
  - trigger notyfikacji push,
  - cykliczne przygotowanie lub odswiezanie sesji.
- `FlashCardsGUI`
  - onboarding i auth,
  - przegladanie zestawow,
  - ekran nauki,
  - ustawienia,
  - rating zestawow.

## Wymagania niefunkcjonalne

- Dane postepu nauki musza byc liczone per uzytkownik i per fiszka.
- Algorytm generacji sesji nie moze gubic zaleglych powtorek.
- System powinien wspierac lokalizacje co najmniej `pl` i `en`.
- Powiadomienia musza byc respektowane zgodnie z preferencjami uzytkownika.
- Social login nie moze duplikowac kont, jesli email jest juz powiazany z istniejacym profilem.

## Proponowane domyslne ustawienia MVP

- Godzina powtorek: `18:00`.
- Dzienny limit nowych fiszek: `20`.
- Dzienny limit powtorek: `100`.
- Liczba pudelek Leitnera: `5`.
- Przykladowe interwaly: `1, 2, 4, 7, 14 dni`.
- Domyslny kanal przypomnien: email wlaczony, push wylaczony.
- Domyslny tryb nauki: wybor przed startem sesji.

## Priorytety MVP

1. Rejestracja i logowanie klasyczne.
2. CRUD prywatnych i publicznych zestawow.
3. Model fiszek i postepu w Leitnerze.
4. Generowanie sesji nauki przez backend.
5. Ekran nauki z trybem ABCD i open answer.
6. Ustawienia dziennego limitu, godziny i interwalow.
7. Scheduler przypomnien email.
8. Rating zestawow spolecznosciowych.
9. Social login Google i Discord.

## Luki wzgledem obecnego repo

- Jest fundament pod auth lokalny, ale brak social login.
- Brak modelu domenowego dla zestawow, fiszek i postepu Leitnera.
- Brak generatora sesji nauki.
- Brak ustawien preferencji nauki i powiadomien.
- `FlashCardsHostedServices` ma tylko testowy scheduler i nie realizuje przypomnien.
- GUI ma obecnie glownie ekrany auth i nie ma flow nauki.

## Najblizszy sensowny krok implementacyjny

Najlepszy kolejny krok to zaprojektowanie encji oraz API dla:

1. `Deck`
2. `Flashcard`
3. `UserFlashcardProgress`
4. `UserPreferences`
5. `StudySession`

To odblokuje jednoczesnie backend, GUI i hosted services.
