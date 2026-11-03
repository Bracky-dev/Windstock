//  main.m -- the container has to be set up here and nowhere later.
//
//  CoreFoundation resolves the home directory once, on first use, and caches
//  it. Every path API in the process is downstream of that, so the only place a
//  redirect can be installed and be believed by everything is before
//  UIApplicationMain -- i.e. here, in the first statement of main().
#import <UIKit/UIKit.h>
#import "WSContainer.h"
#import "WSLog.h"

int main(int argc, char *argv[]) {
    WSContainerBootstrap();
    WSExitTraceInstall();
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"WSAppDelegate");
    }
}
