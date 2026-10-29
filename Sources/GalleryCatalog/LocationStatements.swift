import Foundation
import GalleryDomain
import GallerySQLite

/// The SQL for the two materialised location tables and the geocode cache.
enum LocationStatements {
    /// Every live row that knows where it was taken. `has_gps` is the index, so a 100k library with a
    /// thousand geotagged photos costs a thousand rows, not a scan.
    static let gpsPoints = """
    SELECT id, lat, lon FROM media
    WHERE has_gps = 1 AND trash = 0 AND lat IS NOT NULL AND lon IS NOT NULL
    """

    static let allClusters = """
    SELECT id, center_lat, center_lon, radius_m, item_count, level, name, locality, sublocality,
           admin_area, country, iso_country, place_key, geocoded_ns
    FROM location_cluster ORDER BY item_count DESC, id
    """

    static let insertCluster = """
    INSERT INTO location_cluster (id, center_lat, center_lon, radius_m, item_count, level, name,
                                  locality, sublocality, admin_area, country, iso_country, place_key,
                                  geocoded_ns)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """

    static let insertMember = "INSERT OR IGNORE INTO cluster_member (cluster_id, media_id) VALUES (?, ?)"

    static let assignMember = "UPDATE media SET cluster_id = ?, place_key = ? WHERE id = ?"

    /// Rows whose photos no longer land in any cluster (deleted, or too few to be a place) must not keep
    /// pointing at a cluster id that the next replace will reuse for a different place.
    static let clearMembership = "UPDATE media SET cluster_id = NULL, place_key = NULL WHERE cluster_id IS NOT NULL"

    static let deleteClusters = "DELETE FROM location_cluster"

    static let cachedGeocode = "SELECT payload, did_fail, fetched_ns FROM geocode_cache WHERE key = ?"

    static let storeGeocode = """
    INSERT INTO geocode_cache (key, payload, fetched_ns, did_fail) VALUES (?, ?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET payload = excluded.payload, fetched_ns = excluded.fetched_ns,
                                   did_fail = excluded.did_fail
    """

    static let updateClusterName = """
    UPDATE location_cluster SET name = ?, locality = ?, sublocality = ?, admin_area = ?, country = ?,
                                iso_country = ?, place_key = ?, level = ?, geocoded_ns = ?
    WHERE id = ?
    """

    /// Place albums group by name rather than by cluster, so a name learned after the rows were assigned
    /// still reaches the photos already in the cluster.
    static let assignPlaceKey = "UPDATE media SET place_key = ? WHERE cluster_id = ?"
}
