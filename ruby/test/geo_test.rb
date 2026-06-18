# typed: false
# frozen_string_literal: true

require_relative "test_helper"

class GeoTest < ServerTest
  def setup
    super
    r("GEOADD", "Sicily", "13.361389", "38.115556", "Palermo")
    r("GEOADD", "Sicily", "15.087269", "37.502669", "Catania")
  end

  def test_geodist_meters
    assert_in_delta 166_274.1516, r("GEODIST", "Sicily", "Palermo", "Catania").to_f, 1.0
  end

  def test_geodist_km
    assert_in_delta 166.2742, r("GEODIST", "Sicily", "Palermo", "Catania", "km").to_f, 0.01
  end

  def test_geodist_missing_member
    assert_nil r("GEODIST", "Sicily", "Palermo", "Nowhere")
  end

  def test_geopos
    lon, lat = r("GEOPOS", "Sicily", "Palermo").first
    assert_in_delta 13.361389, lon.to_f, 1e-4
    assert_in_delta 38.115556, lat.to_f, 1e-4
  end

  def test_geopos_missing_member
    assert_nil r("GEOPOS", "Sicily", "Nowhere").first
  end

  def test_geohash
    assert_equal ["sqc8b49rny0"], r("GEOHASH", "Sicily", "Palermo")
  end

  def test_geohash_missing_member
    assert_nil r("GEOHASH", "Sicily", "Nowhere").first
  end

  def test_geosearch_fromlonlat
    members = r("GEOSEARCH", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km", "ASC")
    assert_equal %w[Catania Palermo], members
  end

  def test_geosearch_frommember_withdist
    result = r("GEOSEARCH", "Sicily", "FROMMEMBER", "Palermo", "BYRADIUS", "200", "km", "ASC", "WITHDIST")
    first = result.first
    assert_equal "Palermo", first[0]
    assert_in_delta 0.0, first[1].to_f, 0.01
  end

  def test_geosearchstore
    assert_equal 2, r("GEOSEARCHSTORE", "dest", "Sicily", "FROMLONLAT", "15", "37", "BYRADIUS", "200", "km")
    assert_equal 2, r("ZCARD", "dest")
  end

  def test_georadius
    members = r("GEORADIUS", "Sicily", "15", "37", "200", "km")
    assert_equal %w[Catania Palermo], members.sort
  end

  def test_geoadd_wrong_type
    r("SET", "k", "v")
    assert_error(/WRONGTYPE/, r("GEOADD", "k", "1", "1", "m"))
  end

  def test_geo_key_type_is_zset
    assert_equal "zset", r("TYPE", "Sicily")
  end
end
