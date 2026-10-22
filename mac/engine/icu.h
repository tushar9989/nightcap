// The few ICU C functions the engine calls, from macOS's libicucore (link
// with -licucore). Apple ships the library but not its headers; these match
// ICU's unicode/ucal.h, uloc.h and uldnames.h, and Apple's ualoc.h.

#ifndef NIGHTCAP_ICU_H
#define NIGHTCAP_ICU_H

#include <stdint.h>

typedef uint16_t UChar;
typedef int32_t UErrorCode;  // > 0 is a failure
typedef double UDate;
typedef void *UCalendar;

UCalendar *ucal_open(const UChar *zoneID, int32_t len, const char *locale, int32_t type, UErrorCode *status);
void ucal_close(UCalendar *cal);
void ucal_setMillis(UCalendar *cal, UDate dateTime, UErrorCode *status);
// Options: UCAL_TZ_LOCAL_FORMER = 0x04, UCAL_TZ_LOCAL_LATTER = 0x0C.
void ucal_getTimeZoneOffsetFromLocal(const UCalendar *cal, int32_t nonExistingTimeOpt, int32_t duplicatedTimeOpt,
                                     int32_t *rawOffset, int32_t *dstOffset, UErrorCode *status);

// Locale IDs and language tags.
int32_t uloc_forLanguageTag(const char *langtag, char *localeID, int32_t localeIDCapacity, int32_t *parsedLength, UErrorCode *err);
int32_t uloc_toLanguageTag(const char *localeID, char *langtag, int32_t langtagCapacity, int8_t strict, UErrorCode *err);
// Apple's canonicalization (language and region aliases), which JavaScriptCore uses.
int32_t ualoc_canonicalForm(const char *localeID, char *canonical, int32_t canonicalCapacity, UErrorCode *err);

// Display names. Contexts: UDISPCTX_DIALECT_NAMES = 1, UDISPCTX_CAPITALIZATION_FOR_STANDALONE = 0x104,
// UDISPCTX_LENGTH_FULL = 0x200, UDISPCTX_NO_SUBSTITUTE = 0x301.
typedef struct ULocaleDisplayNames ULocaleDisplayNames;
ULocaleDisplayNames *uldn_openForContext(const char *locale, int32_t *contexts, int32_t length, UErrorCode *status);
int32_t uldn_localeDisplayName(const ULocaleDisplayNames *ldn, const char *locale, UChar *result, int32_t maxResultSize, UErrorCode *status);

#endif
