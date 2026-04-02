# frozen_string_literal: true

class ZipCodeLocation < ActiveRecord::Base
  validates :zip_code, presence: true, uniqueness: true, length: { is: 5 }
  validates :latitude, presence: true
  validates :longitude, presence: true

  # Haversine distance between two points in miles
  EARTH_RADIUS_MILES = 3958.8

  def self.find_by_zip(zip)
    find_by(zip_code: zip.to_s.strip.rjust(5, "0"))
  end

  # Calculate distance in miles between two zip codes.
  # Returns nil if either zip code is not found.
  def self.distance_between(zip_a, zip_b)
    loc_a = find_by_zip(zip_a)
    loc_b = find_by_zip(zip_b)
    return nil unless loc_a && loc_b
    loc_a.distance_to(loc_b)
  end

  # Haversine distance to another ZipCodeLocation in miles
  def distance_to(other)
    return 0.0 if zip_code == other.zip_code

    lat1 = to_rad(latitude)
    lat2 = to_rad(other.latitude)
    dlat = to_rad(other.latitude - latitude)
    dlng = to_rad(other.longitude - longitude)

    a = Math.sin(dlat / 2)**2 +
        Math.cos(lat1) * Math.cos(lat2) * Math.sin(dlng / 2)**2
    c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))

    (EARTH_RADIUS_MILES * c).round(1)
  end

  private

  def to_rad(degrees)
    degrees * Math::PI / 180.0
  end
end
