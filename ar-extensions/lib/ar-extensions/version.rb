
module ActiveRecord # :nodoc:
  module Extensions
    module VERSION  
      MAJOR, MINOR, REVISION = %W( 0 8 2 )
      STRING = [ MAJOR, MINOR, REVISION ].join( '.' )
    end
  end
end
