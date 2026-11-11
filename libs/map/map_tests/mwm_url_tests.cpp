#include "testing/testing.hpp"

#include "map/mwm_url.hpp"

#include "geometry/mercator.hpp"

#include "coding/url.hpp"

#include "base/macros.hpp"

#include <random>
#include <string>

#include "defines.hpp"

namespace mwm_url_tests
{
using namespace std;
using namespace url_scheme;
using UrlType = ParsedMapApi::UrlType;

double const kEps = 1e-10;

UNIT_TEST(MapApiSmoke)
{
  string urlString =
      "mapswithme://"
      "map?ll=38.970559,-9.419289&ignoreThisParam=Yes&z=17&n=Point%20Name&s=black&backurl=https%3A%2F%2Forganicmaps."
      "app";
  TEST(url::Url(urlString).IsValid(), ());

  ParsedMapApi test(urlString);
  TEST_EQUAL(test.GetRequestType(), UrlType::Map, ());
  TEST_EQUAL(test.GetMapPoints().size(), 1, ());
  MapPoint const & p0 = test.GetMapPoints()[0];
  TEST_ALMOST_EQUAL_ABS(p0.m_lat, 38.970559, kEps, ());
  TEST_ALMOST_EQUAL_ABS(p0.m_lon, -9.419289, kEps, ());
  TEST_EQUAL(p0.m_name, "Point Name", ());
  TEST_EQUAL(p0.m_id, "", ());
  TEST_EQUAL(p0.m_style, "black", ());
  TEST_ALMOST_EQUAL_ABS(test.GetZoomLevel(), 17.0, kEps, ());
  TEST_EQUAL(test.GetGlobalBackUrl(), "https://organicmaps.app", ());
}

UNIT_TEST(RouteApiSmoke)
{
  string const urlString = "mapswithme://route?sll=1,1&saddr=name0&dll=2,2&daddr=name1&type=vehicle";
  TEST(url::Url(urlString).IsValid(), ());

  ParsedMapApi test(urlString);
  TEST_EQUAL(test.GetRequestType(), UrlType::Route, ());
  TEST_EQUAL(test.GetRoutePoints().size(), 2, ());
  RoutePoint const & p0 = test.GetRoutePoints()[0];
  RoutePoint const & p1 = test.GetRoutePoints()[1];
  TEST_EQUAL(p0.m_org, mercator::FromLatLon(1, 1), ());
  TEST_EQUAL(p0.m_name, "name0", ());
  TEST_EQUAL(p1.m_org, mercator::FromLatLon(2, 2), ());
  TEST_EQUAL(p1.m_name, "name1", ());
  TEST_EQUAL(test.GetRoutingType(), "vehicle", ());
}

UNIT_TEST(SearchApiSmoke)
{
  string const urlString =
      "mapsme://search?query=Saint%20Hilarion&cll=35.3166654,33.2833322&locale=ru&map&appname=Organic%20Maps";
  TEST(url::Url(urlString).IsValid(), ());

  ParsedMapApi test(urlString);
  TEST_EQUAL(test.GetRequestType(), UrlType::Search, ());
  auto const & request = test.GetSearchRequest();
  ms::LatLon latlon = test.GetCenterLatLon();
  TEST_EQUAL(request.m_query, "Saint Hilarion", ());
  TEST_ALMOST_EQUAL_ABS(latlon.m_lat, 35.3166654, kEps, ());
  TEST_ALMOST_EQUAL_ABS(latlon.m_lon, 33.2833322, kEps, ());
  TEST_EQUAL(request.m_locale, "ru", ());
  TEST_EQUAL(test.GetAppName(), "Organic Maps", ());
  TEST(request.m_isSearchOnMap, ());
}

UNIT_TEST(SearchApiAdvanced)
{
  {
    // Ignore wrong cll=.
    ParsedMapApi test("om://search?query=aaa&cll=1,1,1");
    TEST_EQUAL(test.GetRequestType(), UrlType::Search, ());
    auto const & request = test.GetSearchRequest();
    ms::LatLon latlon = test.GetCenterLatLon();
    TEST_EQUAL(request.m_query, "aaa", ());
    TEST_EQUAL(request.m_locale, "", ());
    TEST(!request.m_isSearchOnMap, ());
    TEST_EQUAL(latlon.m_lat, ms::LatLon::kInvalid, ());
    TEST_EQUAL(latlon.m_lon, ms::LatLon::kInvalid, ());
  }

  {
    // Don't fail on unsupported parameters.
    ParsedMapApi test("om://search?query=aaa&ignoreThisParam=sure");
    TEST_EQUAL(test.GetRequestType(), UrlType::Search, ());
    auto const & request = test.GetSearchRequest();
    ms::LatLon latlon = test.GetCenterLatLon();
    TEST_EQUAL(request.m_query, "aaa", ());
    TEST_EQUAL(request.m_locale, "", ());
    TEST(!request.m_isSearchOnMap, ());
    TEST_EQUAL(latlon.m_lat, ms::LatLon::kInvalid, ());
    TEST_EQUAL(latlon.m_lon, ms::LatLon::kInvalid, ());
  }

  {
    // Query parameter position doesn't matter
    ParsedMapApi test("om://search?cll=1,1&locale=ru&query=aaa");
    TEST_EQUAL(test.GetRequestType(), UrlType::Search, ());
    auto const & request = test.GetSearchRequest();
    ms::LatLon latlon = test.GetCenterLatLon();
    TEST_EQUAL(request.m_query, "aaa", ());
    TEST_EQUAL(request.m_locale, "ru", ());
    TEST(!request.m_isSearchOnMap, ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lat, 1.0, kEps, ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lon, 1.0, kEps, ());
  }
}

UNIT_TEST(SearchApiInvalidUrl)
{
  ParsedMapApi test;
  TEST_EQUAL(test.SetUrlAndParse("mapsme://search?"), UrlType::Incorrect, ("Empty query string"));
  TEST_EQUAL(test.SetUrlAndParse("mapsme://search?query"), UrlType::Incorrect, ("Search query can't be empty"));
  TEST_EQUAL(test.SetUrlAndParse("mapsme://serch?cll=1,1&locale=ru&query=aaa"), UrlType::Incorrect,
             ("Incorrect url type"));
  TEST_EQUAL(test.SetUrlAndParse("mapsme://search?Query=fff"), UrlType::Incorrect, ("The parser is case sensitive"));
  TEST_EQUAL(test.SetUrlAndParse("incorrect://search?query=aaa"), UrlType::Incorrect, ("Wrong prefix"));
  TEST_EQUAL(test.SetUrlAndParse("http://search?query=aaa"), UrlType::Incorrect, ("Wrong prefix"));
}

UNIT_TEST(LeadApiSmoke)
{
  ParsedMapApi test;
  TEST_EQUAL(test.SetUrlAndParse("mapsme://lead?utm_source=a&utm_medium=b&utm_campaign=c&utm_content=d&utm_term=e"),
             UrlType::Incorrect, ("Lead API is not supported"));
}

UNIT_TEST(MapApiInvalidUrl)
{
  ParsedMapApi test;
  TEST_EQUAL(test.SetUrlAndParse("competitors://map?ll=12.3,34.54"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://ggg?ll=12.3,34.54"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mwm://"), UrlType::Incorrect, ("No parameters"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://map?"), UrlType::Incorrect, ("No longtitude"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://map?ll=1,2,3"), UrlType::Incorrect, ("Too many values for ll"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://fffff://map?ll=1,2"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapsme://map?LL=1,1"), UrlType::Incorrect, ("The parser is case sensitive"));
}

UNIT_TEST(RouteApiInvalidUrl)
{
  ParsedMapApi test;
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&saddr=name0&dll=2,2&daddr=name2"), UrlType::Incorrect,
             ("Route type doesn't exist"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&saddr=name0"), UrlType::Incorrect,
             ("Destination doesn't exist"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&dll=2,2&type=vehicle"), UrlType::Incorrect,
             ("Source or destination name doesn't exist"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?saddr=name0&daddr=name1&type=vehicle"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&sll=2.2&type=vehicle"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&dll=2.2&type=666"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&saddr=name0&sll=2,2&saddr=name1&type=vehicle"),
             UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?sll=1,1&type=vehicle"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse(
                 "mapswithme://route?sll=1,1&saddr=name0&sll=2,2&saddr=name1&sll=1,1&saddr=name0&type=vehicle"),
             UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://route?type=vehicle"), UrlType::Incorrect, ());
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://rout?sll=1,1&saddr=name0&dll=2,2&daddr=name1&type=vehicle"),
             UrlType::Incorrect, ());
}

UNIT_TEST(MapApiLatLonLimits)
{
  ParsedMapApi test;
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://map?ll=-91,10"), UrlType::Incorrect, ("Invalid latitude"));
  TEST_EQUAL(test.SetUrlAndParse("mwm://map?ll=523.55,10"), UrlType::Incorrect, ("Invalid latitude"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://map?ll=23.55,450"), UrlType::Incorrect, ("Invalid longtitude"));
  TEST_EQUAL(test.SetUrlAndParse("mapswithme://map?ll=23.55,-450"), UrlType::Incorrect, ("Invalid longtitude"));
}

UNIT_TEST(MapApiPointNameBeforeLatLon)
{
  ParsedMapApi test("mapswithme://map?n=Name&ll=1,2");
  TEST_EQUAL(test.GetRequestType(), UrlType::Incorrect, ());
}

UNIT_TEST(MapApiPointNameOverwritten)
{
  {
    ParsedMapApi api("mapswithme://map?ll=1,2&n=A&N=B");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    TEST_EQUAL(api.GetMapPoints()[0].m_name, "A", ());
  }

  {
    ParsedMapApi api("mapswithme://map?ll=1,2&n=A&n=B");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    TEST_EQUAL(api.GetMapPoints()[0].m_name, "B", ());
  }
}

UNIT_TEST(MapApiMultiplePoints)
{
  ParsedMapApi api("mwm://map?ll=1.1,1.2&n=A&ll=2.1,2.2&ll=-3.1,-3.2&n=C");
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_EQUAL(api.GetMapPoints().size(), 3, ());
  MapPoint const & p0 = api.GetMapPoints()[0];
  TEST_ALMOST_EQUAL_ABS(p0.m_lat, 1.1, kEps, ());
  TEST_ALMOST_EQUAL_ABS(p0.m_lon, 1.2, kEps, ());
  TEST_EQUAL(p0.m_name, "A", ());
  MapPoint const & p1 = api.GetMapPoints()[1];
  TEST_ALMOST_EQUAL_ABS(p1.m_lat, 2.1, kEps, ());
  TEST_ALMOST_EQUAL_ABS(p1.m_lon, 2.2, kEps, ());
  TEST_EQUAL(p1.m_name, "", ());
  MapPoint const & p2 = api.GetMapPoints()[2];
  TEST_ALMOST_EQUAL_ABS(p2.m_lat, -3.1, kEps, ());
  TEST_ALMOST_EQUAL_ABS(p2.m_lon, -3.2, kEps, ());
  TEST_EQUAL(p2.m_name, "C", ());
}

UNIT_TEST(MapApiInvalidPointLatLonButValidOtherParts)
{
  ParsedMapApi api("mapswithme://map?ll=1,1,1&n=A&ll=2,2&n=B&ll=3,3,3&n=C");
  TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
}

UNIT_TEST(MapApiPointURLEncoded)
{
  ParsedMapApi api("mwm://map?ll=1,2&n=%D0%9C%D0%B8%D0%BD%D1%81%D0%BA&id=http%3A%2F%2Fmap%3Fll%3D1%2C2%26n%3Dtest");
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_EQUAL(api.GetMapPoints().size(), 1, ());
  MapPoint const & p0 = api.GetMapPoints()[0];
  TEST_EQUAL(p0.m_name, "\xd0\x9c\xd0\xb8\xd0\xbd\xd1\x81\xd0\xba", ());
  TEST_EQUAL(p0.m_id, "http://map?ll=1,2&n=test", ());
}

UNIT_TEST(MapApiUrl)
{
  {
    ParsedMapApi api("https://www.google.com/maps?q=55.751809,37.6130029");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 55.751809, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 37.6130029, kEps, ());
  }
  {
    ParsedMapApi api("https://www.openstreetmap.org/#map=16/33.89041/35.50664");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 33.89041, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 35.50664, kEps, ());
  }
  {
    ParsedMapApi api("ftp://www.google.com/maps?q=55.751809,37.6130029");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
}

UNIT_TEST(MapApiGe0)
{
  {
    ParsedMapApi api("om://o4B4pYZsRs");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 47.3859, 1e-4, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 8.5766, 1e-4, ());
  }

  {
    ParsedMapApi api("om://o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 47.3859, 1e-4, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 8.5766, 1e-4, ());
    TEST_EQUAL(p0.m_name, "Zoo Zürich", ());
  }
  {
    ParsedMapApi api("http://omaps.app/o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  }
  {
    ParsedMapApi api("https://omaps.app/o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  }
  {
    ParsedMapApi api("ge0://o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  }
  {
    ParsedMapApi api("http://ge0.me/o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  }
  {
    ParsedMapApi api("https://ge0.me/o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  }
  {
    ParsedMapApi api("mapsme://o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    ParsedMapApi api("mwm://o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    ParsedMapApi api("mapswithme://o4B4pYZsRs/Zoo_Zürich");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
}

UNIT_TEST(MapApiClearCoordinates)
{
  {
    // Bare clear coordinates: default zoom, no name.
    ParsedMapApi api("https://omaps.app/48.858093,2.294694");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 48.858093, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 2.294694, kEps, ());
    TEST_EQUAL(p0.m_name, "", ());
    TEST_ALMOST_EQUAL_ABS(api.GetZoomLevel(), 14.0, kEps, ());
  }
  {
    // Zoom from "?z=".
    ParsedMapApi api("https://omaps.app/48.858093,2.294694?z=17");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_ALMOST_EQUAL_ABS(api.GetZoomLevel(), 17.0, kEps, ());
  }
  {
    // Anything url-processor's normalizeZoom rejects keeps the clear-coordinate link's default.
    for (auto const * url :
         {"https://omaps.app/48.858093,2.294694?z=invalid",
          "https://omaps.app/48.858093,2.294694?z=", "https://omaps.app/48.858093,2.294694?z=0",
          "https://omaps.app/48.858093,2.294694?z=-3", "https://omaps.app/48.858093,2.294694?z=1.5",
          "https://omaps.app/48.858093,2.294694?z=16abc", "https://omaps.app/48.858093,2.294694?z=21"})
    {
      ParsedMapApi api(url);
      TEST_EQUAL(api.GetRequestType(), UrlType::Map, (url));
      TEST_ALMOST_EQUAL_ABS(api.GetZoomLevel(), 14.0, kEps, (url));
    }
  }
  {
    // The maximum zoom url-processor accepts is passed through.
    ParsedMapApi api("https://omaps.app/48.858093,2.294694?z=20");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_ALMOST_EQUAL_ABS(api.GetZoomLevel(), 20.0, kEps, ());
  }
  {
    // Name after the coordinates plus "?z=".
    ParsedMapApi api("https://omaps.app/48.858093,2.294694/Eiffel_Tower?z=16");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 48.858093, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 2.294694, kEps, ());
    TEST_EQUAL(p0.m_name, "Eiffel Tower", ());
    TEST_ALMOST_EQUAL_ABS(api.GetZoomLevel(), 16.0, kEps, ());
  }
  {
    // A name starting with a digit must survive (there is no in-path zoom parsing).
    ParsedMapApi api("https://omaps.app/48.858093,2.294694/7-Eleven?z=16");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints()[0].m_name, "7-Eleven", ());
  }
  {
    // Negative coordinates.
    ParsedMapApi api("https://omaps.app/-33.868800,151.209300/Sydney");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, -33.8688, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 151.2093, kEps, ());
    TEST_EQUAL(p0.m_name, "Sydney", ());
  }
  {
    // The om:// scheme works too.
    ParsedMapApi api("om://48.858093,2.294694");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 48.858093, kEps, ());
  }
  {
    // Out-of-range latitude is rejected.
    ParsedMapApi api("https://omaps.app/999.0,0.0");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    // Coordinates must be the whole path head, not embedded into another route.
    ParsedMapApi api("https://omaps.app/foo/48.858093,2.294694");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    // The longitude segment must be fully consumed.
    ParsedMapApi api("https://omaps.app/48.858093,2.294694suffix");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    // Boundary coordinates are valid in the rest of the map API and should be valid here too.
    ParsedMapApi api("https://omaps.app/90.000000,180.000000");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 90.0, kEps, ());
    TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lon, 180.0, kEps, ());
  }
  {
    // A short non-coordinate path is neither a ge0 nor a clear-coordinate link.
    ParsedMapApi api("https://omaps.app/foo");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
}

UNIT_TEST(MapApiGeoScheme)
{
  {
    ParsedMapApi api("geo:0,0?q=35.341714,33.32231 (Custom%20Title)");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 35.341714, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 33.32231, kEps, ());
    TEST_EQUAL(p0.m_name, "Custom Title", ());
  }
  {
    ParsedMapApi api("geo:0,0?q=");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 0.0, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 0.0, kEps, ());
  }
  {
    ParsedMapApi api("geo:0,0");
    TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
    TEST_EQUAL(api.GetMapPoints().size(), 1, ());
    MapPoint const & p0 = api.GetMapPoints()[0];
    TEST_ALMOST_EQUAL_ABS(p0.m_lat, 0.0, kEps, ());
    TEST_ALMOST_EQUAL_ABS(p0.m_lon, 0.0, kEps, ());
  }
}

UNIT_TEST(SearchApiGeoScheme)
{
  {
    ParsedMapApi api("geo:0,0?q=Kyrenia%20Castle");
    TEST_EQUAL(api.GetRequestType(), UrlType::Search, ());
    auto const & request = api.GetSearchRequest();
    ms::LatLon latlon = api.GetCenterLatLon();
    TEST(!latlon.IsValid(), ());
    TEST_EQUAL(request.m_query, "Kyrenia Castle", ());
  }
  {
    ParsedMapApi api("geo:35.3381607,33.3290564?q=Kyrenia%20Castle");
    TEST_EQUAL(api.GetRequestType(), UrlType::Search, ());
    auto const & request = api.GetSearchRequest();
    ms::LatLon latlon = api.GetCenterLatLon();
    TEST_EQUAL(request.m_query, "Kyrenia Castle", ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lat, 35.3381607, kEps, ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lon, 33.3290564, kEps, ());
  }
  {
    ParsedMapApi api("geo:0,0?q=123+Main+St,+Seattle,+WA+98101");
    TEST_EQUAL(api.GetRequestType(), UrlType::Search, ());
    auto const & request = api.GetSearchRequest();
    ms::LatLon latlon = api.GetCenterLatLon();
    TEST(!latlon.IsValid(), ());
    TEST_EQUAL(request.m_query, "123 Main St, Seattle, WA 98101", ());
  }
}

UNIT_TEST(CrosshairApi)
{
  {
    ParsedMapApi api("om://crosshair?cll=47.3813,8.5889&appname=Google%20Maps");
    TEST_EQUAL(api.GetRequestType(), UrlType::Crosshair, ());
    ms::LatLon latlon = api.GetCenterLatLon();
    TEST_ALMOST_EQUAL_ABS(latlon.m_lat, 47.3813, kEps, ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lon, 8.5889, kEps, ());
    TEST_EQUAL(api.GetAppName(), "Google Maps", ());
  }
  {
    ParsedMapApi api("https://omaps.app/crosshair?cll=47.3813,8.5889&appname=Google%20Maps");
    TEST_EQUAL(api.GetRequestType(), UrlType::Crosshair, ());
    ms::LatLon latlon = api.GetCenterLatLon();
    TEST_ALMOST_EQUAL_ABS(latlon.m_lat, 47.3813, kEps, ());
    TEST_ALMOST_EQUAL_ABS(latlon.m_lon, 8.5889, kEps, ());
    TEST_EQUAL(api.GetAppName(), "Google Maps", ());
  }
}

UNIT_TEST(GlobalBackUrl)
{
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName&backurl=someTestAppBackUrl");
    TEST_EQUAL(api.GetGlobalBackUrl(), "someTestAppBackUrl://", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName&backurl=ge0://");
    TEST_EQUAL(api.GetGlobalBackUrl(), "ge0://", ());
  }
  {
    ParsedMapApi api("om://map?ll=1,2&n=PointName&backurl=om://");
    TEST_EQUAL(api.GetGlobalBackUrl(), "om://", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName&backurl=ge0%3A%2F%2F");
    TEST_EQUAL(api.GetGlobalBackUrl(), "ge0://", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName&backurl=http://mapswithme.com");
    TEST_EQUAL(api.GetGlobalBackUrl(), "http://mapswithme.com", ());
  }
  {
    ParsedMapApi api(
        "mwm://map?ll=1,2&n=PointName&backurl=someapp://"
        "%D0%9C%D0%BE%D0%B1%D0%B8%D0%BB%D1%8C%D0%BD%D1%8B%D0%B5%20%D0%9A%D0%B0%D1%80%D1%82%D1%8B");
    TEST_EQUAL(api.GetGlobalBackUrl(),
               "someapp://\xd0\x9c\xd0\xbe\xd0\xb1\xd0\xb8\xd0\xbb\xd1\x8c\xd0\xbd\xd1\x8b\xd0\xb5 "
               "\xd0\x9a\xd0\xb0\xd1\x80\xd1\x82\xd1\x8b",
               ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName");
    TEST_EQUAL(api.GetGlobalBackUrl(), "", ());
  }
  {
    ParsedMapApi api(
        "mwm://"
        "map?ll=1,2&n=PointName&backurl=%D0%BF%D1%80%D0%B8%D0%BB%D0%BE%D0%B6%D0%B5%D0%BD%D0%B8%D0%B5%3A%2F%2F%D0%BE%D1%"
        "82%D0%BA%D1%80%D0%BE%D0%B9%D0%A1%D1%81%D1%8B%D0%BB%D0%BA%D1%83");
    TEST_EQUAL(api.GetGlobalBackUrl(), "приложение://откройСсылку", ());
  }
  {
    ParsedMapApi api(
        "mwm://"
        "map?ll=1,2&n=PointName&backurl=%D0%BF%D1%80%D0%B8%D0%BB%D0%BE%D0%B6%D0%B5%D0%BD%D0%B8%D0%B5%3A%2F%2F%D0%BE%D1%"
        "82%D0%BA%D1%80%D0%BE%D0%B9%D0%A1%D1%81%D1%8B%D0%BB%D0%BA%D1%83");
    TEST_EQUAL(api.GetGlobalBackUrl(), "приложение://откройСсылку", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName&backurl=%E6%88%91%E6%84%9Bmapswithme");
    TEST_EQUAL(api.GetGlobalBackUrl(), "我愛mapswithme://", ());
  }
}

UNIT_TEST(VersionTest)
{
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=1&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 1, ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=kotik&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 0, ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=APacanyVoobsheKotjata&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 0, ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 0, ());
  }
  {
    ParsedMapApi api("mwm://map?V=666&ll=1,2&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 0, ());
  }
  {
    ParsedMapApi api("mwm://map?v=666&ll=1,2&n=PointName");
    TEST_EQUAL(api.GetApiVersion(), 666, ());
  }
}

UNIT_TEST(AppNameTest)
{
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=1&n=PointName&appname=Google");
    TEST_EQUAL(api.GetAppName(), "Google", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=1&n=PointName&appname=%D0%AF%D0%BD%D0%B4%D0%B5%D0%BA%D1%81");
    TEST_EQUAL(api.GetAppName(), "Яндекс", ());
  }
  {
    ParsedMapApi api("mwm://map?ll=1,2&v=1&n=PointName");
    TEST_EQUAL(api.GetAppName(), "", ());
  }
}

UNIT_TEST(OAuth2Test)
{
  {
    ParsedMapApi api("om://oauth2/osm/callback?code=THE_MEGA_CODE");
    TEST_EQUAL(api.GetRequestType(), UrlType::OAuth2, ());
    TEST_EQUAL(api.GetOAuth2Code(), "THE_MEGA_CODE", ());
  }
  {
    ParsedMapApi api("om://oauth2/google/callback?code=THE_MEGA_CODE");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
  {
    ParsedMapApi api("om://oauth2/osm/callback?code=");
    TEST_EQUAL(api.GetRequestType(), UrlType::Incorrect, ());
  }
}

namespace
{
string generatePartOfUrl(url_scheme::MapPoint const & point)
{
  stringstream stream;
  stream << "&ll=" << std::to_string(point.m_lat) << "," << std::to_string(point.m_lon) << "&n=" << point.m_name
         << "&id=" << point.m_id;
  return stream.str();
}

string randomString(size_t size, uint32_t seed)
{
  string result(size, '0');
  mt19937 rng(seed);
  for (size_t i = 0; i < size; ++i)
    result[i] = 'a' + rng() % 26;
  return result;
}

void generateRandomTest(uint32_t numberOfPoints, size_t stringLength)
{
  vector<url_scheme::MapPoint> vect(numberOfPoints);
  for (uint32_t i = 0; i < numberOfPoints; ++i)
  {
    url_scheme::MapPoint point;
    mt19937 rng(i);
    point.m_lat = rng() % 90;
    point.m_lat *= rng() % 2 == 0 ? 1 : -1;
    point.m_lon = rng() % 180;
    point.m_lon *= rng() % 2 == 0 ? 1 : -1;
    point.m_name = randomString(stringLength, i);
    point.m_id = randomString(stringLength, i);
    vect[i] = point;
  }
  string result = "mapswithme://map?v=1";
  for (size_t i = 0; i < vect.size(); ++i)
    result += generatePartOfUrl(vect[i]);

  ParsedMapApi api(result);
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_EQUAL(api.GetMapPoints().size(), vect.size(), ());
  for (size_t i = 0; i < vect.size(); ++i)
  {
    MapPoint const & p = api.GetMapPoints()[i];
    TEST_EQUAL(p.m_name, vect[i].m_name, ());
    TEST_EQUAL(p.m_id, vect[i].m_id, ());
    TEST(AlmostEqualULPs(p.m_lat, vect[i].m_lat), ());
    TEST(AlmostEqualULPs(p.m_lon, vect[i].m_lon), ());
  }
}

}  // namespace

UNIT_TEST(SharedText_ExtractUrl)
{
  // Google Maps on Android: name, address, short link.
  TEST_EQUAL(
      ExtractUrl("Eiffel Tower\nAv. Gustave Eiffel, 75007 Paris, France\nhttps://maps.app.goo.gl/AbC123?g_st=ac"),
      "https://maps.app.goo.gl/AbC123?g_st=ac", ());
  TEST_EQUAL(ExtractUrl("https://maps.app.goo.gl/AbC123"), "https://maps.app.goo.gl/AbC123", ());
  TEST_EQUAL(ExtractUrl("See (https://omaps.app/o4B4pYZsRs/Zoo)."), "https://omaps.app/o4B4pYZsRs/Zoo", ());
  TEST_EQUAL(ExtractUrl("Here: geo:53.9,27.56?z=16, and http://a.b/c"), "geo:53.9,27.56?z=16", ());
  TEST_EQUAL(ExtractUrl("Eiffel Tower, Paris"), "", ());
  TEST_EQUAL(ExtractUrl(""), "", ());
  // Not a link in the middle of a word.
  TEST_EQUAL(ExtractUrl("ftp://a.b xhttps://a.b"), "", ());
}

UNIT_TEST(SharedText_IsShortMapLink)
{
  TEST(IsShortMapLink("https://maps.app.goo.gl/AbC123?g_st=ac"), ());
  TEST(IsShortMapLink("http://goo.gl/maps/AbC123"), ());
  TEST(!IsShortMapLink("https://goo.gl/AbC123"), ());
  TEST(IsShortMapLink("https://maps.apple/p/4q59TQb02Pk6pV"), ());
  TEST(!IsShortMapLink("https://maps.apple/"), ());
  TEST(!IsShortMapLink("https://www.google.com/maps/place/Eiffel+Tower"), ());
  TEST(!IsShortMapLink("geo:53.9,27.56"), ());
  TEST(!IsShortMapLink(""), ());
}

UNIT_TEST(SharedText_ToApiUrl)
{
  auto const typeOf = [](std::string const & url) { return ParsedMapApi(url).GetRequestType(); };

  std::string const text = "Eiffel Tower\nAv. Gustave Eiffel, 75007 Paris\nhttps://maps.app.goo.gl/AbC123";
  std::string const place =
      "https://www.google.com/maps/place/Eiffel+Tower/@48.8583701,2.2919064,17z/data=!4m6!3m5!8m2!3d48.8583736"
      "!4d2.2944813?entry=ttu";

  // The resolved link has the place.
  TEST_EQUAL(SharedTextToApiUrl(text, place), place, ());
  ParsedMapApi api(SharedTextToApiUrl(text, place));
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 48.8583736, kEps, ());
  TEST_EQUAL(api.GetMapPoints()[0].m_name, "Eiffel Tower", ());

  // No network: the short link stays, so the text is searched.
  std::string url = SharedTextToApiUrl(text, "https://maps.app.goo.gl/AbC123");
  TEST_EQUAL(typeOf(url), UrlType::Search, (url));
  TEST_EQUAL(ParsedMapApi(url).GetSearchRequest().m_query, "Eiffel Tower Av. Gustave Eiffel, 75007 Paris", ());

  // Only the link was shared, and it has no coordinates: the place name, then "q=".
  url = SharedTextToApiUrl("https://maps.app.goo.gl/AbC123",
                           "https://www.google.com/maps/place/Caf%C3%A9+de+Flore/data=!4m2!3m1!1s0x0:0x0");
  TEST_EQUAL(ParsedMapApi(url).GetSearchRequest().m_query, "Café de Flore", ());
  url = SharedTextToApiUrl("https://maps.app.goo.gl/AbC123",
                           "https://maps.google.com/?q=Rue+de+Rivoli+1,+Paris&ftid=0x0");
  TEST_EQUAL(ParsedMapApi(url).GetSearchRequest().m_query, "Rue de Rivoli 1, Paris", ());

  // Nothing to show.
  TEST_EQUAL(SharedTextToApiUrl("https://maps.app.goo.gl/AbC123", "https://maps.app.goo.gl/AbC123"), "", ());
  TEST_EQUAL(SharedTextToApiUrl("", ""), "", ());

  // Text without a link, and links that open as they are.
  url = SharedTextToApiUrl("  Kyiv,  Khreshchatyk 1 ", "");
  TEST_EQUAL(ParsedMapApi(url).GetSearchRequest().m_query, "Kyiv, Khreshchatyk 1", ());
  TEST_EQUAL(typeOf(SharedTextToApiUrl("Here geo:53.9,27.56", "geo:53.9,27.56")), UrlType::Map, ());
  TEST_EQUAL(typeOf(SharedTextToApiUrl("", "https://www.openstreetmap.org/#map=16/53.9/27.56")), UrlType::Map, ());
  TEST_EQUAL(typeOf(SharedTextToApiUrl("", "https://omaps.app/o4B4pYZsRs/Zoo")), UrlType::Map, ());
}

// Real links of Google Maps, resolved from maps.app.goo.gl in November 2026, with the tracking parameters cut.
UNIT_TEST(SharedText_GoogleMapsSamples)
{
  // A place: "@" is the map centre, 200 m away from the place.
  ParsedMapApi api(SharedTextToApiUrl(
      "https://maps.app.goo.gl/9T1wfbxMrprjHYAUA",
      "https://www.google.com/maps/place/Flatiron+Building/@43.648436,-79.376746,17z/"
      "data=!3m2!4b1!5s0x89d4cb31fd7e2b53:"
      "0x9a633b5928680c3c!4m6!3m5!1s0x89d4cb2c979b5019:0xa4dcd0f662b39ea5!8m2!3d43.6484321!4d-79.3741711!16s%2Fg%2F"
      "11jf9d4xbb?entry=tts&g_ep=EgoyMDI2MDkxNS4wIPu8ASoASAFQAw%3D%3D"));
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 43.6484321, kEps, ());
  TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lon, -79.3741711, kEps, ());
  TEST_EQUAL(api.GetMapPoints()[0].m_name, "Flatiron Building", ());

  // A Street View photo: only "@".
  api.SetUrlAndParse(SharedTextToApiUrl(
      "https://maps.app.goo.gl/xsM9yzentBL22Fd47",
      "https://www.google.com/maps/place/Karpagam+College+of+Engineering,+Myleripalayam+Village,+Othakkal+Mandapam,+"
      "Tamil+Nadu+641032/@10.8801012,77.0223694,3a,90y,180.79h,106.63t/data=!3m5!1e1!3m3!1sCIHM0ogKEICAgIDMtP_5swE!2e10"
      "!4m2!3m1!1s0x3ba84ffc9b3ea755:0xda7508a90583d22f?utm_source=mstt_0"));
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 10.8801012, kEps, ());

  // A place without coordinates: its name is searched.
  api.SetUrlAndParse(SharedTextToApiUrl(
      "https://maps.app.goo.gl/HDBmrfw9FwKXYDpt7",
      "https://www.google.com/maps/place/Trattoria+no+zu+Tot%C3%B3+e+niputi,+Via+dei+Candelai,+110,+90134+Palermo+PA,+"
      "Italien/data=!4m2!3m1!1s0x1319efe0e678dbfb:0xb9c7cb609cfeb1d3!18m1!1e1?utm_source=mstt_1&entry=gps"));
  TEST_EQUAL(api.GetRequestType(), UrlType::Search, ());
  TEST_EQUAL(api.GetSearchRequest().m_query,
             "Trattoria no zu Totó e niputi, Via dei Candelai, 110, 90134 Palermo PA, Italien", ());

  // A list of places has no place.
  TEST_EQUAL(
      SharedTextToApiUrl("https://maps.app.goo.gl/ATFVu6FJ9oBBpH8K7",
                         "https://www.google.com/maps/@/data=!3m1!4b1!4m3!11m2!2spz4Lz54cq6RodKvvNZbI85htJHaqkw!3e1"
                         "?entry=tts"),
      "", ());
}

UNIT_TEST(SharedText_AppleMapsSamples)
{
  // maps.apple/p/4q59TQb02Pk6pV resolved in November 2026.
  ParsedMapApi api(SharedTextToApiUrl("https://maps.apple/p/4q59TQb02Pk6pV",
                                      "https://maps.apple.com/place?address=900+Brentwood+Rd+NE%2C+Washington%2C+DC++"
                                      "20018%2C+United+States&coordinate=38.9167939%2C-76.9947735"));
  TEST_EQUAL(api.GetRequestType(), UrlType::Map, ());
  TEST_ALMOST_EQUAL_ABS(api.GetMapPoints()[0].m_lat, 38.9167939, kEps, ());

  // No coordinates: the address is searched.
  api.SetUrlAndParse(SharedTextToApiUrl("", "http://maps.apple.com/?q=900%20BRENTWOOD%20RD%20NE%20WASHINGTON%20DC"));
  TEST_EQUAL(api.GetSearchRequest().m_query, "900 BRENTWOOD RD NE WASHINGTON DC", ());
  api.SetUrlAndParse(SharedTextToApiUrl("", "https://maps.apple.com/place?address=Champ+de+Mars,+Paris&place-id=I6A"));
  TEST_EQUAL(api.GetSearchRequest().m_query, "Champ de Mars, Paris", ());
  api.SetUrlAndParse(SharedTextToApiUrl("", "https://maps.apple.com/search?query=Coffee&center=48.85,2.29"));
  TEST_EQUAL(api.GetSearchRequest().m_query, "Coffee", ());
}

UNIT_TEST(100FullEnteriesRandomTest)
{
  generateRandomTest(100, 10);
}

UNIT_TEST(StressTestRandomTest)
{
  generateRandomTest(10000, 100);
}

}  // namespace mwm_url_tests
