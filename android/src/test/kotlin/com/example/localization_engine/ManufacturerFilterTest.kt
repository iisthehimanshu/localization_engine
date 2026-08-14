package com.example.localization_engine

import kotlin.test.Test
import kotlin.test.assertEquals

class ManufacturerFilterTest {
  @Test
  fun manufacturerFiltersContainEveryIwayplusId() {
    assertEquals(setOf(1285, 4336, 2202), IWAYPLUS_MANUFACTURER_IDS.toSet())
    assertEquals(3, IWAYPLUS_MANUFACTURER_IDS.size)
  }
}
