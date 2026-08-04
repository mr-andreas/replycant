#ifndef CLIBGIT2_H
#define CLIBGIT2_H

#if __has_include(<git2.h>)
#import <git2.h>
#import <git2/sys/transport.h>
#import <git2/sys/errors.h>
#elif __has_include(<git2/git2.h>)
#import <git2/git2.h>
#import <git2/sys/transport.h>
#import <git2/sys/errors.h>
#else
#error "Cannot find git2.h"
#endif

#endif /* CLIBGIT2_H */

