//
//  PlugIn.h
//  obs-mac-virtualcam
//
//  Created by John Boiles  on 4/9/20.
//
//  obs-mac-virtualcam is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 2 of the License, or
//  (at your option) any later version.
//
//  obs-mac-virtualcam is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with obs-mac-virtualcam. If not, see <http://www.gnu.org/licenses/>.

#import "OBSDALObjectStore.h"
#import "OBSDALMachClient.h"
#import "OBSDALStream.h"
#import "vcam-brand-macos.h"

#define kTestCardWidthKey  @VIRTUALCAM_TEST_CARD_WIDTH_KEY
#define kTestCardHeightKey @VIRTUALCAM_TEST_CARD_HEIGHT_KEY
#define kTestCardFPSKey    @VIRTUALCAM_TEST_CARD_FPS_KEY

NS_ASSUME_NONNULL_BEGIN

@interface OBSDALPlugin : NSObject <CMIOObject>

@property CMIOObjectID objectId;
@property (readonly) OBSDALMachClient *machClient;
@property OBSDALStream *stream;

+ (OBSDALPlugin *)SharedPlugIn;

- (void)initialize;

- (void)teardown;

- (void)startStream;

- (void)stopStream;

@end

NS_ASSUME_NONNULL_END
