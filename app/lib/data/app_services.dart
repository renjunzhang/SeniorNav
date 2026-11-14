import '../core/contracts.dart';
import 'baidu_client.dart';
import 'local_place_repository.dart';
import 'navigation_service.dart';
import 'route_service.dart';

Future<AppServices> createAppServices() async {
  final places = LocalPlaceRepository();
  await places.initialize();
  final client = BaiduClient(privacyAccepted: () => places.privacyAccepted);
  return AppServices(
    places: places,
    poi: SdkPoiService(client),
    routes: SdkRouteService(client),
    navigation: BaiduNavigationService(),
    cache: places,
    trip: places,
  );
}
