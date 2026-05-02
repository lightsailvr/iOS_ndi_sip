//  stereondi-Bridging-Header.h
//
//  Bridging header exposing the ObjC++ NDI wrappers to Swift.
//  Each granular wrapper (NDIRuntime, NDIDiscovery, NDIReceiver, NDISender) gets
//  imported here as it lands in its own slice. Keep imports alphabetized.

#ifndef stereondi_Bridging_Header_h
#define stereondi_Bridging_Header_h

#import "NDI/NDIDiscoveryFirstSource.h"
#import "NDI/NDIReceiver.h"
#import "NDI/NDIRuntime.h"

#endif /* stereondi_Bridging_Header_h */
