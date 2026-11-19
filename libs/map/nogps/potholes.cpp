#include "map/nogps/potholes.hpp"

#include "map/nogps/geo.hpp"

#include "coding/internal/file_data.hpp"

#include "base/logging.hpp"
#include "base/string_utils.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>

namespace nogps
{
std::optional<PotholeDetector::Hit> PotholeDetector::OnSample(int64_t timeMs, double joltMs2, int speedKmh,
                                                              std::optional<ms::LatLon> const & place)
{
  std::optional<Hit> ended;
  if (m_hit && timeMs - m_hitStartMs >= kHitGapMs)
  {
    ended = m_hit;
    m_hit.reset();
  }
  if (joltMs2 < kJoltMs2 || speedKmh < kMinKmh || !place)
    return ended;
  if (!m_hit)
  {
    m_hit = Hit{joltMs2, *place, speedKmh};
    m_hitStartMs = timeMs;
  }
  else if (joltMs2 > m_hit->m_joltMs2)
  {
    m_hit = Hit{joltMs2, *place, speedKmh};
  }
  return ended;
}

int PotholeStore::ToPct(double joltMs2)
{
  return std::min(100, static_cast<int>(std::lround(joltMs2 / kAccelFullScaleMs2 * 100)));
}

PotholeStore::Added PotholeStore::Add(ms::LatLon const & place, int pct, int64_t unixMs)
{
  Pothole * nearest = nullptr;
  double nearestM = kMergeM;
  for (auto & pothole : m_potholes)
  {
    double const distanceM = Distance(pothole.m_place, place);
    if (distanceM <= nearestM)
    {
      nearest = &pothole;
      nearestM = distanceM;
    }
  }
  if (nearest)
  {
    ++nearest->m_hits;
    nearest->m_pct = std::max(nearest->m_pct, pct);
    nearest->m_lastUnixMs = unixMs;
    return {*nearest, true};
  }

  Pothole const pothole{place, pct, 1, unixMs};
  m_potholes.push_back(pothole);
  if (m_potholes.size() > kMax)
  {
    m_potholes.erase(std::min_element(m_potholes.begin(), m_potholes.end(), [](Pothole const & a, Pothole const & b)
    { return a.m_lastUnixMs < b.m_lastUnixMs; }));
  }
  return {pothole, false};
}

void PotholeStore::Load(std::string const & path)
{
  m_potholes.clear();
  std::ifstream file(path);
  std::string line;
  while (std::getline(file, line))
  {
    auto const parts = strings::Tokenize(line, ",");
    Pothole pothole;
    if (parts.size() != 5 || !strings::to_double(parts[0], pothole.m_place.m_lat) ||
        !strings::to_double(parts[1], pothole.m_place.m_lon) || !strings::to_int(parts[2], pothole.m_pct) ||
        !strings::to_int(parts[3], pothole.m_hits) || !strings::to_int(parts[4], pothole.m_lastUnixMs))
    {
      LOG(LWARNING, ("Wrong pothole line", line));
      continue;
    }
    m_potholes.push_back(pothole);
  }
  if (!m_potholes.empty())
    LOG(LINFO, ("Potholes =", m_potholes.size()));
}

bool PotholeStore::Save(std::string const & path) const
{
  return base::WriteToTempAndRenameToFile(path, [this](std::string const & tmp)
  {
    std::ofstream file(tmp);
    for (auto const & p : m_potholes)
    {
      char buf[96];
      std::snprintf(buf, sizeof(buf), "%.6f,%.6f,%d,%d,%lld\n", p.m_place.m_lat, p.m_place.m_lon, p.m_pct, p.m_hits,
                    static_cast<long long>(p.m_lastUnixMs));
      file << buf;
    }
    file.close();
    return !file.fail();
  });
}
}  // namespace nogps
