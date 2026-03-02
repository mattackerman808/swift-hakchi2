/* libssh2 config for SwiftHakchi — mbedTLS backend, macOS */
#ifndef LIBSSH2_CONFIG_H
#define LIBSSH2_CONFIG_H

/* Use mbedTLS as the crypto backend */
#define LIBSSH2_MBEDTLS 1

/* Standard headers */
#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_STRTOLL 1
#define HAVE_SNPRINTF 1

/* Include sys/uio.h for struct iovec */
#include <sys/uio.h>

/* macOS specifics */
#define HAVE_O_NONBLOCK 1

/* Compression disabled (not needed for our use case) */
/* #undef LIBSSH2_HAVE_ZLIB */

#endif /* LIBSSH2_CONFIG_H */
