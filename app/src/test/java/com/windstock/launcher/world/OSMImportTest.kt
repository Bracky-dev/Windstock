package com.windstock.launcher.world

import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.io.File

/**
 * The on-phone converter against the rules it copies. Pure parts always; a whole
 * extract when OSM_PBF points at one (the iOS converter's output is compared by
 * tools/check_osm_import.sh, which writes OSM_OUT here and diffs the two).
 */
class OSMImportTest {
    @Test fun names() {
        assertEquals("Texas", OSMImport.displayName("texas-latest.osm.pbf"))
        assertEquals("New Mexico", OSMImport.displayName("new-mexico-latest.osm.pbf"))
        assertEquals("osm-north-america-us-texas", OSMImport.packID("north-america/us/texas"))
    }

    @Test fun gymRule() {
        // _is_gym: a landmark always; otherwise int(md5(oid)) % 6 == 0.
        assertEquals(true, OSMImport.classify("n1", "Town Hall", listOf("townhall"))?.first)
        assertEquals(null, OSMImport.classify("n1", "Bench", listOf("bench")))
        assertEquals(null, OSMImport.classify("n1", "  ", listOf("cafe")))
        val cp = OSMImport.classify("n9", "x".repeat(60), listOf("cafe"))!!.second
        assertEquals(40, cp.length)
    }

    @Test fun s2() {
        // s2sphere: CellId.from_lat_lng(LatLng.from_degrees(51.5, -0.12)).parent(15).id()
        // as signed 64-bit, the way build_world_db stores it.
        assertEquals(0x487604c740000000L, S2Cell.id(51.5, -0.12))
    }

    @Test fun wholeExtract() {
        val pbf = System.getenv("OSM_PBF")
        assumeTrue("set OSM_PBF to convert a real extract", pbf != null)
        val f = File(pbf!!)
        val (forts, scanned) = OSMImport.extract({ f.inputStream() to f.length() })
        val out = File(System.getenv("OSM_OUT") ?: "build/osm-forts.tsv")
        out.bufferedWriter().use { w ->
            for (x in forts) w.write("${x.id}\t${x.lat}\t${x.lng}\t${if (x.gym) 1 else 0}\t${S2Cell.id(x.lat, x.lng)}\t${x.name}\n")
        }
        println("kotlin: forts=${forts.size} gyms=${forts.count { it.gym }} scanned=$scanned -> $out")
    }
}
